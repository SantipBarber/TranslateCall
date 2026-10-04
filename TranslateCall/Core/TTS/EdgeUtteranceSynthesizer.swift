import AVFoundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "EdgeUtteranceSynthesizer")

// MARK: - EdgeUtteranceSynthesizer

/// Microsoft Edge neural voices (cloud) as an `UtteranceSynthesizer` (F8.5.2 REQ-T-02/05/26). The MP3
/// is collected until `turn.end` and decoded once, in memory. A connection found dead, or lost before
/// any audio, is re-established once; timeouts are not retried, so the fallback speaks within 5 s.
nonisolated final class EdgeUtteranceSynthesizer: UtteranceSynthesizer {
    let engine: TTSEngine = .edgeTTS
    private let socket: EdgeTTSWebSocket

    init(socket: EdgeTTSWebSocket = EdgeTTSWebSocket()) {
        self.socket = socket
    }

    func canSpeak(_ locale: Locale) -> Bool {
        EdgeTTSVoiceCatalog.defaultVoice(for: locale) != nil
    }

    func synthesize(text: String, locale: Locale) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let (stream, continuation) = UtteranceStream.make()
        guard let voice = EdgeTTSVoiceCatalog.defaultVoice(for: locale)?.shortName else {
            continuation.finish(throwing: STSError.voiceUnavailable(locale))
            return stream
        }
        let producer = Task { [socket] in
            do {
                let mp3 = try await Self.fetchAudio(socket: socket, text: text, voice: voice)
                let pcm = try EdgeMP3Decoder.decode(mp3)
                try Task.checkCancellation()
                continuation.yield(pcm)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in producer.cancel() }
        return stream
    }

    func shutdown() async {
        await socket.disconnect()
    }

    /// The whole MP3 of one utterance, reconnecting once if the connection was lost before any audio.
    static func fetchAudio(socket: EdgeTTSWebSocket, text: String, voice: String) async throws -> Data {
        do {
            return try await attempt(socket: socket, text: text, voice: voice)
        } catch let failure as EdgeAttemptFailure {
            guard failure.isRetryable else { throw failure.error }
            try Task.checkCancellation()
            logger.info("Edge TTS: reconnecting once after \(failure.error.localizedDescription, privacy: .public)")
            await socket.disconnect()
            do {
                return try await attempt(socket: socket, text: text, voice: voice)
            } catch let second as EdgeAttemptFailure {
                throw second.error
            }
        }
    }

    private static func attempt(socket: EdgeTTSWebSocket, text: String, voice: String) async throws -> Data {
        do {
            try await socket.connect()
        } catch {
            throw EdgeAttemptFailure(error: error, beforeAudio: true)
        }
        var audio = Data()
        do {
            for try await chunk in socket.synthesize(text: text, voice: voice) { audio.append(chunk) }
        } catch {
            throw EdgeAttemptFailure(error: error, beforeAudio: audio.isEmpty)
        }
        guard !audio.isEmpty else { throw EdgeTTSError.emptyAudio }
        return audio
    }
}

/// One failed Edge turn, and whether reconnecting may fix it (REQ-T-26).
nonisolated struct EdgeAttemptFailure: Error {
    let error: Error
    let beforeAudio: Bool

    /// Only a connection lost before any audio is retried; a timeout means the network is slow or
    /// down, and retrying would only delay the fallback.
    var isRetryable: Bool {
        guard beforeAudio, let edgeError = error as? EdgeTTSError else { return false }
        switch edgeError {
        case .connectionClosed, .connectionFailed, .notConnected: return true
        default: return false
        }
    }
}
