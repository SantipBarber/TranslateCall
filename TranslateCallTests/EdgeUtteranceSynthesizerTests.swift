import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

@Suite("EdgeUtteranceSynthesizer")
struct EdgeUtteranceSynthesizerTests {

    /// The fixture split into three Edge audio frames, then turn.end.
    private func reply() throws -> [EdgeSocketEvent] {
        let mp3 = try edgeMP3Fixture()
        let third = mp3.count / 3
        let parts = [mp3.prefix(third), mp3.dropFirst(third).prefix(third), mp3.dropFirst(2 * third)]
        return parts.map { .binary(FakeEdgeTransport.audioFrame(Data($0))) } + [FakeEdgeTransport.turnEnd]
    }

    private func synthesizer(_ transport: FakeEdgeTransport, clock: TestClock = TestClock()) -> EdgeUtteranceSynthesizer {
        EdgeUtteranceSynthesizer(socket: EdgeTTSWebSocket(transport: transport, clock: clock))
    }

    @Test("the MP3 chunks of one turn are decoded in memory into one 24 kHz mono buffer (REQ-T-05)")
    func decodesTurn() async throws {
        let transport = FakeEdgeTransport(onSSML: [try reply()])
        let buffers = try #require(try await collect(synthesizer(transport).synthesize(text: "Hello", locale: english)))
        let pcm = try #require(buffers.first)
        #expect(buffers.count == 1)
        #expect(pcm.format.sampleRate == 24_000)
        #expect(pcm.format.channelCount == 1)
        let expected = try AVAudioFile(forReading: edgeMP3FixtureURL()).length   // file-based decode
        #expect(abs(Int64(pcm.frameLength) - expected) <= expected / 20)
    }

    @Test("a connection that died while idle is re-established once, transparently (REQ-T-26)")
    func reconnectsOnce() async throws {
        let transport = FakeEdgeTransport(onSSML: [[.peerClosed], try reply()])
        let buffers = try await collect(synthesizer(transport).synthesize(text: "Hello", locale: english))
        #expect(buffers?.count == 1)
        #expect(transport.connectCount == 2)
    }

    @Test("a second failure in a row throws (REQ-T-26)")
    func secondFailureThrows() async {
        let transport = FakeEdgeTransport(onSSML: [[.peerClosed]])
        await #expect(throws: EdgeTTSError.connectionClosed) {
            _ = try await collect(synthesizer(transport).synthesize(text: "Hello", locale: english))
        }
        #expect(transport.connectCount == 2)
    }

    @Test("a failure after audio arrived is not retried")
    func failureAfterAudioNotRetried() async throws {
        let first = try #require(try reply().first)
        let transport = FakeEdgeTransport(onSSML: [[first, .peerClosed]])
        await #expect(throws: EdgeTTSError.connectionClosed) {
            _ = try await collect(synthesizer(transport).synthesize(text: "Hello", locale: english))
        }
        #expect(transport.connectCount == 1)
    }

    @Test("a timeout is not retried, so the fallback can speak within 5 s (design §4)")
    func timeoutNotRetried() async {
        let clock = TestClock()
        let transport = FakeEdgeTransport(onSSML: [[]])
        let stream = synthesizer(transport, clock: clock).synthesize(text: "Hello", locale: english)
        let consumer = Task { try await collect(stream) }
        #expect(await waitUntil { clock.pendingDeadlines == [.seconds(5), .seconds(20)] })
        clock.advance(by: .seconds(5))
        await #expect(throws: EdgeTTSError.firstChunkTimeout) { _ = try await consumer.value }
        #expect(transport.connectCount == 1)
    }

    @Test("Review focus: turn.end with no audio is a failure, so the playback service falls back (not silence, A3b)")
    func emptyTurnFallsBack() async {
        let transport = FakeEdgeTransport(onSSML: [[FakeEdgeTransport.turnEnd]])
        let fallback = FakeSynthesizer(engine: .avSpeech)
        let service = TTSPlaybackService(primary: synthesizer(transport), fallback: fallback,
                                         output: FakeOutput(autoComplete: true), clock: TestClock())
        let events = StreamRecorder(service.events)
        await service.speak(text: "Hello", locale: english)
        #expect(await waitUntil { events.values == [.fellBack(from: .edgeTTS, to: .avSpeech)] })
        #expect(await waitUntil { fallback.texts == ["Hello"] })
        await service.deactivate()
    }

    @Test("shutdown (TTSPlaybackService.deactivate) disconnects the socket")
    func shutdownDisconnects() async throws {
        let transport = FakeEdgeTransport(onSSML: [try reply()])
        let edge = synthesizer(transport)
        _ = try await collect(edge.synthesize(text: "Hello", locale: english))
        let before = transport.disconnectCount
        await edge.shutdown()
        #expect(transport.disconnectCount == before + 1)
    }

    @Test("bytes that are not MP3 fail to decode; no bytes is emptyAudio")
    func decoderRejectsGarbage() {
        #expect(throws: EdgeTTSError.self) { _ = try EdgeMP3Decoder.decode(Data([1, 2, 3, 4, 5])) }
        #expect(throws: EdgeTTSError.emptyAudio) { _ = try EdgeMP3Decoder.decode(Data()) }
    }

    @Test("speaks the catalog's locales only")
    func canSpeak() {
        let edge = synthesizer(FakeEdgeTransport())
        #expect(edge.canSpeak(Locale(identifier: "uk-UA")))
        #expect(!edge.canSpeak(Locale(identifier: "xx-XX")))
    }
}
