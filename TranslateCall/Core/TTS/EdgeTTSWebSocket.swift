import Foundation
import Network
import OSLog

private nonisolated let logger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "EdgeTTSWebSocket"
)

// MARK: - EdgeTTSWebSocket

/// WebSocket client for Microsoft Edge TTS using raw TLS + manual handshake.
///
/// Apple's `NWProtocolWebSocket` and `URLSessionWebSocketTask` filter custom headers
/// (notably `Origin`), so we perform the HTTP/1.1 upgrade ourselves over a plain
/// TLS `NWConnection`. This gives full control over all headers including the
/// `Origin: chrome-extension://…` that Microsoft requires.
actor EdgeTTSWebSocket {

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.spbarber.EdgeTTSWebSocket")

    // MARK: - Connect

    func connect() async throws {
        if connection != nil { return }

        let connId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let gecToken = EdgeTTSDRM.generateSecMsGec()
        let path = "\(EdgeTTSConstants.path)"
            + "?TrustedClientToken=\(EdgeTTSConstants.trustedClientToken)"
            + "&ConnectionId=\(connId)"
            + "&Sec-MS-GEC=\(gecToken)"
            + "&Sec-MS-GEC-Version=\(EdgeTTSConstants.secMsGecVersion)"

        // Raw TLS connection (no WebSocket protocol layer — we do the upgrade ourselves)
        let tlsOptions = NWProtocolTLS.Options()
        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(EdgeTTSConstants.host),
            port: .https
        )
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        // Wait for TCP+TLS ready
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

        // WebSocket upgrade handshake
        let wsKey = EdgeTTSDRM.generateWebSocketKey()
        try await performWebSocketUpgrade(conn: conn, path: path, wsKey: wsKey)
        logger.debug("Edge TTS WebSocket connected")

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

    // MARK: - WebSocket Upgrade

    private func performWebSocketUpgrade(
        conn: NWConnection, path: String, wsKey: String
    ) async throws {
        var request = "GET \(path) HTTP/1.1\r\n"
        request += "Host: \(EdgeTTSConstants.host)\r\n"
        request += "Upgrade: websocket\r\n"
        request += "Connection: Upgrade\r\n"
        request += "Sec-WebSocket-Key: \(wsKey)\r\n"
        request += "Sec-WebSocket-Version: 13\r\n"
        request += "Origin: \(EdgeTTSConstants.origin)\r\n"
        request += "User-Agent: \(EdgeTTSConstants.userAgent)\r\n"
        request += "Pragma: no-cache\r\n"
        request += "Cache-Control: no-cache\r\n"
        request += "Accept-Encoding: gzip, deflate, br, zstd\r\n"
        request += "Accept-Language: en-US,en;q=0.9\r\n"
        request += "\r\n"

        // Send upgrade request
        try await sendRaw(conn: conn, data: Data(request.utf8))

        // Read response (may arrive in chunks)
        let response = try await readHTTPResponse(conn: conn)

        guard response.contains("HTTP/1.1 101") || response.contains("HTTP/1.0 101") else {
            logger.error("WebSocket upgrade rejected: \(response.prefix(200))")
            throw EdgeTTSError.handshakeRejected(response)
        }
    }

    private func readHTTPResponse(conn: NWConnection) async throws -> String {
        var accumulated = Data()
        let headerEnd = Data("\r\n\r\n".utf8)

        // Read until we see \r\n\r\n (end of HTTP headers)
        while !accumulated.wsContains(headerEnd) {
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: data ?? Data())
                    }
                }
            }
            guard !chunk.isEmpty else { throw EdgeTTSError.notConnected }
            accumulated.append(chunk)
        }

        return String(data: accumulated, encoding: .utf8) ?? ""
    }

    // MARK: - WebSocket Frame Send

    private func sendText(_ text: String) async throws {
        guard let conn = connection else { throw EdgeTTSError.notConnected }
        let payload = Data(text.utf8)
        let frame = WSFrameEncoder.encodeFrame(opcode: 0x01, payload: payload) // 0x01 = text
        try await sendRaw(conn: conn, data: frame)
    }

    private func sendRaw(conn: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(
                content: data,
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

    // Frame encoding delegated to WSFrameEncoder (reduces actor body length).

    // MARK: - WebSocket Frame Receive

    private func receiveLoop(
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        while true {
            let (opcode, payload) = try await receiveFrame()

            switch opcode {
            case 0x01: // text
                if let str = String(data: payload, encoding: .utf8),
                   str.contains("Path:turn.end") {
                    continuation.finish()
                    return
                }
            case 0x02: // binary
                if let audio = extractAudioData(from: payload) {
                    continuation.yield(audio)
                }
            case 0x08: // close
                continuation.finish()
                return
            case 0x09: // ping → send pong
                try await sendPong(payload: payload)
            default:
                break
            }
        }
    }

    private func receiveFrame() async throws -> (opcode: UInt8, payload: Data) {
        guard let conn = connection else { throw EdgeTTSError.notConnected }

        // Read first 2 bytes: [FIN+opcode] [mask+length]
        let header = try await readExact(conn: conn, count: 2)
        let opcode = header[0] & 0x0F
        let masked = (header[1] & 0x80) != 0
        var payloadLength = UInt64(header[1] & 0x7F)

        // Extended length
        if payloadLength == 126 {
            let ext = try await readExact(conn: conn, count: 2)
            payloadLength = UInt64(ext[0]) << 8 | UInt64(ext[1])
        } else if payloadLength == 127 {
            let ext = try await readExact(conn: conn, count: 8)
            payloadLength = 0
            for byte in ext {
                payloadLength = (payloadLength << 8) | UInt64(byte)
            }
        }

        // Mask key (server→client is normally unmasked, but handle it)
        var maskKey: [UInt8]?
        if masked {
            let maskData = try await readExact(conn: conn, count: 4)
            maskKey = Array(maskData)
        }

        // Payload
        guard payloadLength <= 10_000_000 else { throw EdgeTTSError.synthesisTimeout }
        var payload = try await readExact(conn: conn, count: Int(payloadLength))

        // Unmask if needed
        if let mask = maskKey {
            for idx in payload.indices {
                payload[idx] ^= mask[(idx - payload.startIndex) % 4]
            }
        }

        return (opcode, payload)
    }

    private func readExact(conn: NWConnection, count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        var accumulated = Data()
        accumulated.reserveCapacity(count)

        while accumulated.count < count {
            let remaining = count - accumulated.count
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                conn.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: remaining
                ) { data, _, _, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else {
                        cont.resume(throwing: EdgeTTSError.notConnected)
                    }
                }
            }
            accumulated.append(chunk)
        }
        return accumulated
    }

    private func sendPong(payload: Data) async throws {
        guard let conn = connection else { return }
        let frame = WSFrameEncoder.encodeFrame(opcode: 0x0A, payload: payload) // 0x0A = pong
        try await sendRaw(conn: conn, data: frame)
    }

    // MARK: - Audio extraction

    private func extractAudioData(from data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let headerLen = Int(data[0]) << 8 | Int(data[1])
        let audioStart = 2 + headerLen
        guard audioStart < data.count else { return nil }
        return data.subdata(in: audioStart..<data.count)
    }

    // MARK: - Message builders (nonisolated — pure string construction)

    private nonisolated func buildConfigMessage() -> String {
        EdgeTTSMessageBuilder.configMessage()
    }

    private nonisolated func buildSSML(
        text: String, voice: String,
        rate: Int, pitch: Int, volume: Int
    ) -> String {
        EdgeTTSMessageBuilder.ssml(
            text: text, voice: voice, rate: rate, pitch: pitch, volume: volume
        )
    }
}

// MARK: - Data helper

private extension Data {
    nonisolated func wsContains(_ other: Data) -> Bool {
        guard other.count <= count else { return false }
        return range(of: other) != nil
    }
}
