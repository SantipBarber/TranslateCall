import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "EdgeTTSWebSocket")

// MARK: - EdgeTimeouts

/// Edge TTS time limits (REQ-T-25), injectable for tests.
nonisolated struct EdgeTimeouts: Sendable {
    var connect: Duration = .seconds(5)
    /// From sending the SSML to the first audio chunk.
    var firstChunk: Duration = .seconds(5)
    /// From sending the SSML to `turn.end`.
    var utterance: Duration = .seconds(20)

    static let `default` = EdgeTimeouts()
}

// MARK: - EdgeTTSWebSocket

/// One Edge TTS connection (F8.5.2 REQ-T-24…27). `isConnected` follows the socket's own events: a
/// closing event, or the end of the connection's event stream, clears it and discards the stream.
/// One utterance at a time is guaranteed by the playback worker.
actor EdgeTTSWebSocket {
    private let transport: any EdgeTransport
    private let timeouts: EdgeTimeouts
    private let clock: any Clock<Duration>

    private(set) var isConnected = false
    /// Bumped by every connect/disconnect, so events of an older connection are ignored.
    private var connectionID: UInt64 = 0
    private var inbox: AsyncStream<EdgeSocketEvent>?
    private var pump: Task<Void, Never>?

    init(
        transport: any EdgeTransport = StarscreamTransport(),
        timeouts: EdgeTimeouts = .default,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.transport = transport
        self.timeouts = timeouts
        self.clock = clock
    }

    // MARK: Connect

    /// Connects unless already connected, then sends the speech config. Throws after `timeouts.connect`.
    func connect() async throws {
        if isConnected { return }
        let request = try Self.makeRequest()
        disconnect()
        let id = connectionID
        let events = transport.connect(request: request)
        let (inbox, inboxContinuation) = AsyncStream.makeStream(
            of: EdgeSocketEvent.self, bufferingPolicy: .bufferingNewest(EdgeSocketEvent.bufferLimit)
        )
        self.inbox = inbox
        // The pump updates the connection state before the reader sees each event (REQ-T-24).
        pump = Task { [weak self] in
            for await event in events {
                await self?.observe(event, connection: id)
                inboxContinuation.yield(event)
            }
            inboxContinuation.finish()
            await self?.connectionEnded(id)
        }
        do {
            try await Self.withTimeout(timeouts.connect, clock: clock, error: EdgeTTSError.connectTimeout) {
                try await Self.awaitConnected(inbox)
            }
        } catch {
            if id == connectionID { disconnect() }
            throw error
        }
        guard id == connectionID, isConnected else { throw EdgeTTSError.connectionClosed }
        transport.write(string: EdgeTTSMessageBuilder.configMessage())
        logger.debug("Edge TTS connected")
    }

    // MARK: Synthesize

    /// Sends the SSML and streams the MP3 chunks; finishes on `turn.end`, throws on a close, an
    /// error or a timeout before it (REQ-T-24/25).
    nonisolated func synthesize(text: String, voice: String) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: Data.self, throwing: Error.self, bufferingPolicy: .bufferingNewest(EdgeSocketEvent.bufferLimit)
        )
        let turn = Task { await self.run(text: text, voice: voice, into: continuation) }
        continuation.onTermination = { _ in turn.cancel() }
        return stream
    }

    // MARK: Disconnect

    func disconnect() {
        connectionID &+= 1
        isConnected = false
        inbox = nil
        pump?.cancel()
        pump = nil
        transport.disconnect()
    }

    // MARK: Private

    private func run(text: String, voice: String, into output: AsyncThrowingStream<Data, Error>.Continuation) async {
        guard isConnected, let inbox else {
            output.finish(throwing: EdgeTTSError.notConnected)
            return
        }
        let id = connectionID
        transport.write(string: EdgeTTSMessageBuilder.ssml(text: text, voice: voice, rate: 0, pitch: 0, volume: 0))
        let timeouts = self.timeouts
        let clock = self.clock
        do {
            try await Self.withTimeout(timeouts.utterance, clock: clock, error: EdgeTTSError.synthesisTimeout) {
                try await Self.receive(inbox, timeouts: timeouts, clock: clock, into: output)
            }
            output.finish()
        } catch {
            if id == connectionID { disconnect() }   // state unknown after a failed or abandoned turn
            output.finish(throwing: error)
        }
    }

    private func observe(_ event: EdgeSocketEvent, connection id: UInt64) {
        guard id == connectionID else { return }
        if event == .connected { isConnected = true }
        if event.isClosing {
            isConnected = false
            inbox = nil
        }
    }

    private func connectionEnded(_ id: UInt64) {
        guard id == connectionID else { return }
        isConnected = false
        inbox = nil
    }

    private static func makeRequest() throws -> URLRequest {
        let connectionToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let path = EdgeTTSConstants.path
            + "?TrustedClientToken=\(EdgeTTSConstants.trustedClientToken)"
            + "&ConnectionId=\(connectionToken)"
            + "&Sec-MS-GEC=\(EdgeTTSDRM.generateSecMsGec())"
            + "&Sec-MS-GEC-Version=\(EdgeTTSConstants.secMsGecVersion)"
        guard let url = URL(string: "wss://\(EdgeTTSConstants.host)\(path)") else { throw EdgeTTSError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(EdgeTTSConstants.origin, forHTTPHeaderField: "Origin")
        request.setValue(EdgeTTSConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return request
    }

    // MARK: Event reading (static: runs in the timeout's child tasks)

    private static func awaitConnected(_ events: AsyncStream<EdgeSocketEvent>) async throws {
        for await event in events {
            switch event {
            case .connected: return
            case .error(let message): throw EdgeTTSError.connectionFailed(message)
            case .disconnected, .cancelled, .peerClosed: throw EdgeTTSError.connectionClosed
            case .text, .binary: continue
            }
        }
        throw EdgeTTSError.connectionClosed
    }

    /// Phase 1 until the first audio chunk (`timeouts.firstChunk`), phase 2 until `turn.end`.
    private static func receive(
        _ events: AsyncStream<EdgeSocketEvent>,
        timeouts: EdgeTimeouts,
        clock: any Clock<Duration>,
        into output: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        let ended = try await withTimeout(timeouts.firstChunk, clock: clock, error: EdgeTTSError.firstChunkTimeout) {
            try await readAudio(events, into: output, untilFirstChunk: true)
        }
        if !ended { _ = try await readAudio(events, into: output, untilFirstChunk: false) }
    }

    /// Yields audio chunks; returns true at `turn.end`, or false right after the first chunk when asked.
    private static func readAudio(
        _ events: AsyncStream<EdgeSocketEvent>,
        into output: AsyncThrowingStream<Data, Error>.Continuation,
        untilFirstChunk: Bool
    ) async throws -> Bool {
        for await event in events {
            switch event {
            case .binary(let frame):
                guard let audio = extractAudioData(from: frame) else { continue }
                output.yield(audio)
                if untilFirstChunk { return false }
            case .text(let message):
                if message.contains("Path:turn.end") { return true }
            case .error(let message):
                throw EdgeTTSError.connectionFailed(message)
            case .disconnected, .cancelled, .peerClosed:
                throw EdgeTTSError.connectionClosed
            case .connected:
                continue
            }
        }
        throw EdgeTTSError.connectionClosed   // the connection's stream ended (or this read was cancelled)
    }

    /// Runs `operation`; if `limit` passes first, cancels it and throws `timeoutError`.
    private static func withTimeout<T: Sendable>(
        _ limit: Duration,
        clock: any Clock<Duration>,
        error timeoutError: EdgeTTSError,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await clock.sleep(for: limit)
                throw timeoutError
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw timeoutError }
            return first
        }
    }

    /// Edge binary frames: 2-byte big-endian header length, the header, then MP3 bytes.
    nonisolated static func extractAudioData(from data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let headerLength = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
        let audioStart = data.startIndex + 2 + headerLength
        guard audioStart < data.endIndex else { return nil }
        return data.subdata(in: audioStart..<data.endIndex)
    }
}
