import CommonCrypto
import Foundation
import Security

// MARK: - WebSocket Frame Encoder

/// Encodes WebSocket frames per RFC 6455.
enum WSFrameEncoder {
    /// Encodes a WebSocket frame with masking (client → server must be masked).
    nonisolated static func encodeFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode) // FIN + opcode

        let length = payload.count
        if length < 126 {
            frame.append(UInt8(length) | 0x80)
        } else if length < 65536 {
            frame.append(126 | 0x80)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127 | 0x80)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> shift) & 0xFF))
            }
        }

        var maskKey = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &maskKey)
        frame.append(contentsOf: maskKey)

        for (idx, byte) in payload.enumerated() {
            frame.append(byte ^ maskKey[idx % 4])
        }
        return frame
    }
}

// MARK: - EdgeTTS DRM

/// Generates authentication tokens for Edge TTS WebSocket.
enum EdgeTTSDRM {
    /// SHA-256( windowsTicks_rounded_5min + TRUSTED_CLIENT_TOKEN ).uppercased()
    nonisolated static func generateSecMsGec() -> String {
        let winEpoch: Int64 = 11_644_473_600
        let now = Int64(Date().timeIntervalSince1970)
        var ticks = now + winEpoch
        ticks -= ticks % 300
        let filetime = ticks * 10_000_000
        let input = "\(filetime)\(EdgeTTSConstants.trustedClientToken)"

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let data = Data(input.utf8)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02X", $0) }.joined()
    }

    /// Random 16-byte base64 WebSocket key.
    nonisolated static func generateWebSocketKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        return Data(bytes).base64EncodedString()
    }
}

// MARK: - EdgeTTS Message Builder

enum EdgeTTSMessageBuilder {
    nonisolated static func configMessage() -> String {
        "Content-Type:application/json; charset=utf-8\r\n"
            + "Path:speech.config\r\n\r\n"
            + "{\"context\":{\"synthesis\":{\"audio\":{"
            + "\"metadataoptions\":{"
            + "\"sentenceBoundaryEnabled\":\"false\","
            + "\"wordBoundaryEnabled\":\"false\"},"
            + "\"outputFormat\":\"\(EdgeTTSConstants.outputFormat)\"}}}}"
    }

    nonisolated static func ssml(
        text: String, voice: String,
        rate: Int, pitch: Int, volume: Int
    ) -> String {
        let reqId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
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
}

// MARK: - EdgeTTSConstants

enum EdgeTTSConstants: Sendable {
    nonisolated static let host = "speech.platform.bing.com"
    nonisolated static let path = "/consumer/speech/synthesize/readaloud/edge/v1"
    nonisolated static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    nonisolated static let outputFormat = "audio-24khz-48kbitrate-mono-mp3"
    nonisolated static let origin = "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold"
    nonisolated static let chromiumVersion = "143.0.3650.75"
    nonisolated static let secMsGecVersion = "1-\(chromiumVersion)"
    // swiftlint:disable:next line_length
    nonisolated static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0"
}

// MARK: - EdgeTTSError

enum EdgeTTSError: LocalizedError {
    case invalidURL
    case notConnected
    case synthesisTimeout
    case handshakeRejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Edge TTS endpoint URL."
        case .notConnected: return "Edge TTS not connected."
        case .synthesisTimeout: return "Edge TTS synthesis timed out."
        case .handshakeRejected(let response):
            return "Edge TTS handshake rejected: \(response.prefix(100))"
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
