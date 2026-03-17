import Foundation
import Network
import OSLog

private nonisolated let logger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "EdgeTTSWebSocket"
)

// MARK: - EdgeTTSWebSocket

/// WebSocket client for Microsoft Edge TTS using Network.framework (NWConnection).
/// Uses NWConnection instead of URLSessionWebSocketTask to support custom Origin header.
actor EdgeTTSWebSocket {

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.spbarber.EdgeTTSWebSocket")

    // MARK: - Constants

    private static let host = "speech.platform.bing.com"
    private static let path = "/consumer/speech/synthesize/readaloud/edge/v1"
    private static let token = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let outputFormat = "audio-24khz-48kbitrate-mono-mp3"
    // swiftlint:disable:next line_length
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0"
    private static let origin = "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold"
    nonisolated static let webSocketHeaders: [(String, String)] = [
        ("User-Agent", userAgent),
        ("Origin", origin),
        ("Pragma", "no-cache"),
        ("Cache-Control", "no-cache")
    ]

    // MARK: - Connect

    func connect() async throws {
        if connection != nil { return }

        let connId = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.setAdditionalHeaders(Self.webSocketHeaders)
        wsOptions.autoReplyPing = true

        let parameters = NWParameters.tls
        parameters.defaultProtocolStack.applicationProtocols
            .insert(wsOptions, at: 0)

        let urlString = "wss://\(Self.host)\(Self.path)"
            + "?TrustedClientToken=\(Self.token)"
            + "&ConnectionId=\(connId)"
        guard let url = URL(string: urlString) else {
            throw EdgeTTSError.invalidURL
        }
        let endpoint = NWEndpoint.url(url)
        let conn = NWConnection(to: endpoint, using: parameters)
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume()
                case .failed(let error):
                    resumed = true
                    cont.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    cont.resume(throwing: EdgeTTSError.notConnected)
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
        }

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
        try await sendText(configPayload)
        logger.debug("Edge TTS connected via NWConnection")
    }

    // MARK: - Synthesize

    func synthesize(
        text: String,
        voice: String,
        rate: Int = 0,
        pitch: Int = 0,
        volume: Int = 0
    ) async throws -> AsyncThrowingStream<Data, Error> {
        guard connection != nil else {
            throw EdgeTTSError.notConnected
        }

        let requestId = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
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

        try await sendText(ssml)

        return AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    try await self.receiveLoop(continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - Private: Send

    private func sendText(_ text: String) async throws {
        guard let conn = connection else {
            throw EdgeTTSError.notConnected
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "edgeTTS",
            metadata: [metadata]
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(
                content: text.data(using: .utf8),
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            )
        }
    }

    // MARK: - Private: Receive

    private func receiveLoop(
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        while true {
            let (data, context) = try await receiveMessage()

            // Check WebSocket metadata for opcode
            let metadata = context?.protocolMetadata(
                definition: NWProtocolWebSocket.definition
            ) as? NWProtocolWebSocket.Metadata

            switch metadata?.opcode {
            case .binary:
                if let audioData = extractAudioData(from: data) {
                    continuation.yield(audioData)
                }
            case .text:
                if let text = String(data: data, encoding: .utf8),
                   text.contains("Path:turn.end") {
                    continuation.finish()
                    return
                }
            case .close:
                continuation.finish()
                return
            default:
                break
            }
        }
    }

    private func receiveMessage() async throws -> (Data, NWConnection.ContentContext?) {
        guard let conn = connection else {
            throw EdgeTTSError.notConnected
        }
        return try await withCheckedThrowingContinuation { cont in
            conn.receiveMessage { content, context, _, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: (content ?? Data(), context))
                }
            }
        }
    }

    /// Extracts MP3 audio from a binary WebSocket message.
    /// Binary messages have a 2-byte header length prefix.
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
