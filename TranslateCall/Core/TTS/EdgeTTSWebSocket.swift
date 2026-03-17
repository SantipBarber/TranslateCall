import Foundation
import Network
import OSLog

private nonisolated let logger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "EdgeTTSWebSocket"
)

// MARK: - EdgeTTSWebSocket

/// WebSocket client for Microsoft Edge TTS using Network.framework.
actor EdgeTTSWebSocket {

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.spbarber.EdgeTTSWebSocket")

    // MARK: - Constants

    private static let host = "speech.platform.bing.com"
    private static let path = "/consumer/speech/synthesize/readaloud/edge/v1"
    private static let token = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let outputFormat = "audio-24khz-48kbitrate-mono-mp3"

    // MARK: - Connect

    func connect() async throws {
        if connection != nil { return }

        let connId = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
        let urlString = "wss://\(Self.host)\(Self.path)"
            + "?TrustedClientToken=\(Self.token)"
            + "&ConnectionId=\(connId)"
        guard let url = URL(string: urlString) else {
            throw EdgeTTSError.invalidURL
        }

        // Let NWConnection auto-configure WebSocket from wss:// URL
        let conn = NWConnection(
            to: .url(url), using: .tls
        )
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    logger.debug("Edge TTS WebSocket connected")
                    cont.resume()
                case .failed(let error):
                    resumed = true
                    logger.error("Edge TTS connect failed: \(error)")
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
        try await sendText(buildConfigMessage())
        logger.debug("Edge TTS config sent")
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

        try await sendText(
            buildSSML(text: text, voice: voice, rate: rate, pitch: pitch, volume: volume)
        )

        return AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    try await self.receiveLoop(
                        continuation: continuation
                    )
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

    // MARK: - Message builders

    private func buildConfigMessage() -> String {
        "Content-Type:application/json; charset=utf-8\r\n"
            + "Path:speech.config\r\n\r\n"
            + "{\"context\":{\"synthesis\":{\"audio\":{"
            + "\"metadataoptions\":{"
            + "\"sentenceBoundaryEnabled\":\"false\","
            + "\"wordBoundaryEnabled\":\"false\"},"
            + "\"outputFormat\":\"\(Self.outputFormat)\"}}}}"
    }

    private func buildSSML(
        text: String, voice: String,
        rate: Int, pitch: Int, volume: Int
    ) -> String {
        let reqId = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
        let rateStr = rate >= 0 ? "+\(rate)%" : "\(rate)%"
        let pitchStr = pitch >= 0 ? "+\(pitch)Hz" : "\(pitch)Hz"
        let volStr = volume >= 0 ? "+\(volume)%" : "\(volume)%"

        return "X-RequestId:\(reqId)\r\n"
            + "Content-Type:application/ssml+xml\r\n"
            + "Path:ssml\r\n\r\n"
            + "<speak version='1.0' "
            + "xmlns='http://www.w3.org/2001/10/synthesis' "
            + "xml:lang='en-US'>"
            + "<voice name='\(voice)'>"
            + "<prosody rate='\(rateStr)' pitch='\(pitchStr)' "
            + "volume='\(volStr)'>"
            + "\(text.escapedForXML)"
            + "</prosody></voice></speak>"
    }

    // MARK: - Send/Receive

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

    private func receiveLoop(
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        while true {
            let (data, context) = try await receiveMessage()
            let metadata = context?.protocolMetadata(
                definition: NWProtocolWebSocket.definition
            ) as? NWProtocolWebSocket.Metadata

            switch metadata?.opcode {
            case .binary:
                if let audio = extractAudioData(from: data) {
                    continuation.yield(audio)
                }
            case .text:
                if let str = String(data: data, encoding: .utf8),
                   str.contains("Path:turn.end") {
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
        case .notConnected: return "Edge TTS not connected."
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
