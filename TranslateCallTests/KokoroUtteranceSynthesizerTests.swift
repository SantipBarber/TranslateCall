import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

@Suite("KokoroUtteranceSynthesizer")
struct KokoroUtteranceSynthesizerTests {

    /// A synthesizer over a mock Kokoro model; `loading` (if given) holds the model load open.
    private func make(_ mock: MockKokoroTtsManager, loading: AsyncGate? = nil) -> KokoroUtteranceSynthesizer {
        let manager = KokoroModelManager(managerFactory: { _ in
            if let loading { await loading.wait() }
            return mock
        })
        return KokoroUtteranceSynthesizer(modelManager: manager)
    }

    @Test("yields one 24 kHz mono buffer holding the model's samples")
    func yieldsSamples() async throws {
        let mock = MockKokoroTtsManager()
        await mock.stubResult([0.1, 0.2, 0.3, 0.4])
        let buffers = try #require(try await collect(make(mock).synthesize(text: "Hello", locale: english)))
        #expect(buffers.count == 1)
        #expect(buffers.first?.format.sampleRate == 24_000)
        #expect(buffers.first?.format.channelCount == 1)
        #expect(buffers.first?.frameLength == 4)
    }

    @Test("text over 500 characters is cut at a word boundary; exactly 500 is kept (REQ-T-04)")
    func truncation() async throws {
        let mock = MockKokoroTtsManager()
        let synthesizer = make(mock)
        _ = try await collect(synthesizer.synthesize(text: String(repeating: "hello ", count: 92), locale: english))
        _ = try await collect(synthesizer.synthesize(text: String(repeating: "a", count: 500), locale: english))
        let received = await mock.receivedTexts
        #expect(received.count == 2)
        #expect(received[0].count <= 500)
        #expect(!received[0].hasSuffix(" "))
        #expect(received[1].count == 500)
    }

    @Test("no samples from the model: the stream fails, never a silent success, so the service falls back")
    func emptySamples() async {
        let mock = MockKokoroTtsManager()
        await mock.stubResult([])
        await #expect(throws: KokoroUtteranceError.emptyOutput) {
            _ = try await collect(make(mock).synthesize(text: "Hello", locale: english))
        }
    }

    @Test("a model error fails the stream, so the playback service can fall back")
    func modelErrorThrows() async {
        let mock = MockKokoroTtsManager()
        await mock.stubError(FakeSynthError.boom)
        await #expect(throws: FakeSynthError.boom) {
            _ = try await collect(make(mock).synthesize(text: "Hi", locale: english))
        }
    }

    @Test("stopped while the model loads: the sentence is never synthesized (A9)")
    func cancelledWhileLoading() async {
        let mock = MockKokoroTtsManager()
        let loading = AsyncGate()
        let stream = make(mock, loading: loading).synthesize(text: "stale", locale: english)
        let consumer = Task { for try await _ in stream {} }
        #expect(await waitUntil { loading.waiterCount == 1 })

        consumer.cancel()                         // what TTSPlaybackService does on stopSpeaking
        _ = await consumer.result
        loading.open()

        // Bounded wait for something that must not happen.
        #expect(!(await waitUntil(timeout: .milliseconds(300)) { await mock.callCount > 0 }))
    }

    @Test("English only")
    func englishOnly() {
        let synthesizer = make(MockKokoroTtsManager())
        #expect(synthesizer.canSpeak(Locale(identifier: "en-GB")))
        #expect(!synthesizer.canSpeak(Locale(identifier: "fr-FR")))
    }
}
