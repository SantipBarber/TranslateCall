import Foundation
import OSLog
import Starscream

private nonisolated let logger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "EdgeTTSWebSocket"
)

// MARK: - EdgeTTSWebSocket

/// WebSocket client for Microsoft Edge TTS using Starscream.
///
/// Starscream allows full control over HTTP headers (including `Origin`),
/// which Apple's native WebSocket APIs filter out.
actor EdgeTTSWebSocket {

    private var socket: WebSocket?
    private var delegate: WebSocketBridge?
    private var eventStream: AsyncStream<WebSocketEvent>?
    private var eventContinuation: AsyncStream<WebSocketEvent>.Continuation?
    private var isConnected = false

    // MARK: - Connect

    func connect() async throws {
        if isConnected { return }

        let connId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let gecToken = EdgeTTSDRM.generateSecMsGec()
        let path = "\(EdgeTTSConstants.path)"
            + "?TrustedClientToken=\(EdgeTTSConstants.trustedClientToken)"
            + "&ConnectionId=\(connId)"
            + "&Sec-MS-GEC=\(gecToken)"
            + "&Sec-MS-GEC-Version=\(EdgeTTSConstants.secMsGecVersion)"

        guard let url = URL(
            string: "wss://\(EdgeTTSConstants.host)\(path)"
        ) else {
            throw EdgeTTSError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(EdgeTTSConstants.origin, forHTTPHeaderField: "Origin")
        request.setValue(EdgeTTSConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        // Create event stream for async bridging
        var cont: AsyncStream<WebSocketEvent>.Continuation?
        let stream = AsyncStream<WebSocketEvent> { cont = $0 }
        self.eventStream = stream
        self.eventContinuation = cont

        let bridge = WebSocketBridge(continuation: cont!)
        self.delegate = bridge

        let ws = WebSocket(request: request)
        ws.delegate = bridge
        self.socket = ws
        ws.connect()

        // Wait for connection
        for await event in stream {
            switch event {
            case .connected:
                isConnected = true
                logger.debug("Edge TTS WebSocket connected")

                // Send speech config
                try await sendText(EdgeTTSMessageBuilder.configMessage())
                logger.debug("Edge TTS config sent")
                return

            case .error(let error):
                throw error ?? EdgeTTSError.notConnected

            case .cancelled, .peerClosed:
                throw EdgeTTSError.notConnected

            default:
                continue
            }
        }

        throw EdgeTTSError.notConnected
    }

    // MARK: - Synthesize

    /// Synthesizes text to audio and returns the complete MP3 data.
    func synthesize(
        text: String,
        voice: String,
        rate: Int = 0,
        pitch: Int = 0,
        volume: Int = 0
    ) async throws -> Data {
        guard isConnected else {
            throw EdgeTTSError.notConnected
        }

        let ssml = EdgeTTSMessageBuilder.ssml(
            text: text, voice: voice, rate: rate, pitch: pitch, volume: volume
        )
        try await sendText(ssml)

        guard let stream = eventStream else {
            throw EdgeTTSError.notConnected
        }

        var audioData = Data()

        for await event in stream {
            switch event {
            case .text(let str):
                if str.contains("Path:turn.end") {
                    return audioData
                }

            case .binary(let data):
                if let audio = Self.extractAudioData(from: data) {
                    audioData.append(audio)
                }

            case .error(let error):
                throw error ?? EdgeTTSError.notConnected

            case .cancelled, .peerClosed, .disconnected:
                return audioData

            default:
                continue
            }
        }

        return audioData
    }

    // MARK: - Disconnect

    func disconnect() {
        socket?.disconnect()
        socket = nil
        delegate = nil
        eventContinuation?.finish()
        eventContinuation = nil
        eventStream = nil
        isConnected = false
    }

    // MARK: - Send

    private func sendText(_ text: String) async throws {
        guard let socket else { throw EdgeTTSError.notConnected }
        socket.write(string: text)
    }

    // MARK: - Audio extraction

    private nonisolated static func extractAudioData(from data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let headerLen = Int(data[0]) << 8 | Int(data[1])
        let audioStart = 2 + headerLen
        guard audioStart < data.count else { return nil }
        return data.subdata(in: audioStart..<data.count)
    }
}

// MARK: - WebSocketBridge

/// Bridges Starscream's delegate callbacks into an AsyncStream.
private final class WebSocketBridge: @unchecked Sendable, WebSocketDelegate {

    private let continuation: AsyncStream<WebSocketEvent>.Continuation

    nonisolated init(continuation: AsyncStream<WebSocketEvent>.Continuation) {
        self.continuation = continuation
    }

    nonisolated func didReceive(event: WebSocketEvent, client: any WebSocketClient) {
        switch event {
        case .connected(let headers):
            logger.debug("WS connected, headers: \(headers.count)")
            continuation.yield(.connected(headers))

        case .disconnected(let reason, let code):
            logger.info("WS disconnected: \(reason) (\(code))")
            continuation.yield(.disconnected(reason, code))
            continuation.finish()

        case .text(let string):
            continuation.yield(.text(string))

        case .binary(let data):
            continuation.yield(.binary(data))

        case .ping:
            break // Starscream auto-responds with pong

        case .pong:
            break

        case .viabilityChanged(let viable):
            if !viable {
                logger.warning("WS viability lost")
            }

        case .reconnectSuggested:
            break

        case .cancelled:
            logger.info("WS cancelled")
            continuation.yield(.cancelled)
            continuation.finish()

        case .error(let error):
            logger.error("WS error: \(String(describing: error))")
            continuation.yield(.error(error))
            continuation.finish()

        case .peerClosed:
            logger.info("WS peer closed")
            continuation.yield(.peerClosed)
            continuation.finish()
        }
    }
}
