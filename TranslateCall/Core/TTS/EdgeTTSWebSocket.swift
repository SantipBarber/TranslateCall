import Foundation
import OSLog

private nonisolated let logger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "EdgeTTSWebSocket"
)

// MARK: - EdgeTTSWebSocket

/// WebSocket client for Microsoft Edge TTS (reverse-engineered protocol).
/// Connects to `speech.platform.bing.com`, sends SSML, receives MP3 audio chunks.
actor EdgeTTSWebSocket {

    private var webSocket: URLSessionWebSocketTask?
    private let session: URLSession

    // MARK: - Constants

    private static let endpoint = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
    private static let token = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let outputFormat = "audio-24khz-48kbitrate-mono-mp3"

    // MARK: - Init

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Connect

    func connect() async throws {
        if webSocket != nil { return }

        let connId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard var components = URLComponents(string: Self.endpoint) else {
            throw EdgeTTSError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: Self.token),
            URLQueryItem(name: "ConnectionId", value: connId)
        ]
        guard let url = components.url else {
            throw EdgeTTSError.invalidURL
        }

        // Use URLSessionConfiguration with custom headers since
        // URLSessionWebSocketTask may strip some headers (like Origin).
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0",
            "Origin": "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
            "Pragma": "no-cache",
            "Cache-Control": "no-cache"
        ]
        let customSession = URLSession(configuration: config)
        let task = customSession.webSocketTask(with: url)
        task.resume()
        self.webSocket = task

        // Send speech config
        let configPayload = """
        Content-Type:application/json; charset=utf-8\r
        Path:speech.config\r
        \r
        {"context":{"synthesis":{"audio":{"metadataoptions":{\
        "sentenceBoundaryEnabled":"false",\
        "wordBoundaryEnabled":"false"},\
        "outputFormat":"\(Self.outputFormat)"}}}}
        """
        try await task.send(.string(configPayload))
        logger.debug("Edge TTS connected")
    }

    // MARK: - Synthesize

    /// Sends SSML and returns an AsyncThrowingStream of MP3 Data chunks.
    func synthesize(
        text: String,
        voice: String,
        rate: Int = 0,
        pitch: Int = 0,
        volume: Int = 0
    ) async throws -> AsyncThrowingStream<Data, Error> {
        guard let socket = webSocket else {
            throw EdgeTTSError.notConnected
        }

        let requestId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let rateStr = rate >= 0 ? "+\(rate)%" : "\(rate)%"
        let pitchStr = pitch >= 0 ? "+\(pitch)Hz" : "\(pitch)Hz"
        let volStr = volume >= 0 ? "+\(volume)%" : "\(volume)%"

        let ssml = """
        X-RequestId:\(requestId)\r
        Content-Type:application/ssml+xml\r
        Path:ssml\r
        \r
        <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>\
        <voice name='\(voice)'>\
        <prosody rate='\(rateStr)' pitch='\(pitchStr)' volume='\(volStr)'>\
        \(text.escapedForXML)\
        </prosody></voice></speak>
        """

        try await socket.send(.string(ssml))

        return AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    try await self.receiveLoop(socket: socket, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
    }

    // MARK: - Private

    private func receiveLoop(
        socket: URLSessionWebSocketTask,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        while true {
            let message = try await socket.receive()
            switch message {
            case .data(let data):
                // Binary messages contain a header + MP3 audio
                if let audioData = extractAudioData(from: data) {
                    continuation.yield(audioData)
                }
            case .string(let text):
                if text.contains("Path:turn.end") {
                    continuation.finish()
                    return
                }
            @unknown default:
                break
            }
        }
    }

    /// Extracts MP3 audio from a binary WebSocket message.
    /// Binary messages have a 2-byte header length prefix, then header, then audio.
    private func extractAudioData(from data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let headerLen = Int(data[0]) << 8 | Int(data[1])
        let audioStart = 2 + headerLen
        guard audioStart < data.count else { return nil }
        return data.subdata(in: audioStart..<data.count)
    }
}

// MARK: - EdgeTTSError

enum EdgeTTSError: LocalizedError {
    case invalidURL
    case notConnected
    case synthesisTimeout

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Edge TTS endpoint URL."
        case .notConnected: return "Edge TTS WebSocket not connected."
        case .synthesisTimeout: return "Edge TTS synthesis timed out."
        }
    }
}

// MARK: - String XML escape

extension String {
    nonisolated var escapedForXML: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
