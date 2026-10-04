import Foundation
import Testing
@testable import TranslateCall

@Suite("EdgeTTSWebSocket")
struct EdgeTTSWebSocketTests {
    private let audio = Data([0x01, 0x02, 0x03])

    private func socket(_ transport: FakeEdgeTransport, clock: TestClock = TestClock()) -> EdgeTTSWebSocket {
        EdgeTTSWebSocket(transport: transport, clock: clock)
    }

    @Test("connect waits for .connected, then sends speech.config")
    func connectSendsConfig() async throws {
        let transport = FakeEdgeTransport()
        let ws = socket(transport)
        try await ws.connect()
        #expect(await ws.isConnected)
        #expect(transport.written.first?.contains("Path:speech.config") == true)
    }

    @Test("a closing event while idle clears isConnected (REQ-T-24, A3b)",
          arguments: [EdgeSocketEvent.peerClosed, .cancelled, .disconnected("bye (1000)"), .error("reset")])
    func closingEventDisconnects(_ event: EdgeSocketEvent) async throws {
        let transport = FakeEdgeTransport()
        let ws = socket(transport)
        try await ws.connect()
        transport.push(event)
        #expect(await waitUntil { await !ws.isConnected })
    }

    @Test("synthesize yields the audio chunks in order and finishes on turn.end")
    func streamsChunks() async throws {
        let transport = FakeEdgeTransport(onSSML: [[
            .text("Path:turn.start"),
            .binary(FakeEdgeTransport.audioFrame(Data([1]))),
            .binary(FakeEdgeTransport.audioFrame(Data([2, 3]))),
            FakeEdgeTransport.turnEnd
        ]])
        let ws = socket(transport)
        try await ws.connect()
        var chunks: [Data] = []
        for try await chunk in ws.synthesize(text: "Hi", voice: "en-US-JennyNeural") { chunks.append(chunk) }
        #expect(chunks == [Data([1]), Data([2, 3])])
        #expect(await ws.isConnected)
        #expect(transport.ssmlCount == 1)
    }

    @Test("a close before turn.end throws connectionClosed and leaves the socket disconnected")
    func closeBeforeTurnEnd() async throws {
        let transport = FakeEdgeTransport(onSSML: [[.binary(FakeEdgeTransport.audioFrame(audio)), .peerClosed]])
        let ws = socket(transport)
        try await ws.connect()
        await #expect(throws: EdgeTTSError.connectionClosed) {
            for try await _ in ws.synthesize(text: "Hi", voice: "en-US-JennyNeural") {}
        }
        #expect(await !ws.isConnected)
    }

    @Test("synthesize without a connection throws notConnected")
    func notConnected() async {
        let ws = socket(FakeEdgeTransport())
        await #expect(throws: EdgeTTSError.notConnected) {
            for try await _ in ws.synthesize(text: "Hi", voice: "en-US-JennyNeural") {}
        }
    }

    @Test("connect gives up after 5 s (REQ-T-25, A3c)")
    func connectTimeout() async {
        let clock = TestClock()
        let transport = FakeEdgeTransport(onConnect: [[]])          // the server never answers
        let ws = socket(transport, clock: clock)
        let connecting = Task { try await ws.connect() }
        #expect(await waitUntil { clock.pendingDeadlines == [.seconds(5)] })
        clock.advance(by: .seconds(5))
        await #expect(throws: EdgeTTSError.connectTimeout) { try await connecting.value }
        #expect(await !ws.isConnected)
    }

    @Test("no first audio chunk within 5 s of the SSML throws firstChunkTimeout (REQ-T-25)")
    func firstChunkTimeout() async throws {
        let clock = TestClock()
        let ws = socket(FakeEdgeTransport(), clock: clock)
        try await ws.connect()
        let turn = Task { for try await _ in ws.synthesize(text: "Hi", voice: "en-US-JennyNeural") {} }
        #expect(await waitUntil { clock.pendingDeadlines == [.seconds(5), .seconds(20)] })
        clock.advance(by: .seconds(5))
        await #expect(throws: EdgeTTSError.firstChunkTimeout) { try await turn.value }
    }

    @Test("audio that never reaches turn.end is cut at 20 s (REQ-T-25)")
    func utteranceTimeout() async throws {
        let clock = TestClock()
        let transport = FakeEdgeTransport(onSSML: [[.binary(FakeEdgeTransport.audioFrame(audio))]])
        let ws = socket(transport, clock: clock)
        try await ws.connect()
        let turn = Task { for try await _ in ws.synthesize(text: "Hi", voice: "en-US-JennyNeural") {} }
        #expect(await waitUntil { clock.pendingDeadlines == [.seconds(20)] })   // the first chunk arrived
        clock.advance(by: .seconds(20))
        await #expect(throws: EdgeTTSError.synthesisTimeout) { try await turn.value }
    }

    @Test("extractAudioData skips the header and rejects frames without audio")
    func extractAudioData() {
        #expect(EdgeTTSWebSocket.extractAudioData(from: FakeEdgeTransport.audioFrame(Data([9, 8]))) == Data([9, 8]))
        #expect(EdgeTTSWebSocket.extractAudioData(from: Data([0, 1])) == nil)            // too short
        #expect(EdgeTTSWebSocket.extractAudioData(from: Data([0, 5, 1, 2])) == nil)      // header longer than data
        #expect(EdgeTTSWebSocket.extractAudioData(from: FakeEdgeTransport.audioFrame(Data())) == nil)
    }

    @Test("disconnect closes the transport and clears isConnected")
    func disconnect() async throws {
        let transport = FakeEdgeTransport()
        let ws = socket(transport)
        try await ws.connect()
        let before = transport.disconnectCount
        await ws.disconnect()
        #expect(await !ws.isConnected)
        #expect(transport.disconnectCount == before + 1)
    }
}
