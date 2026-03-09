import AVFoundation
import Foundation
import Speech

// MARK: - TranscriptionResult

/// A finalized speech recognition result for one utterance.
struct TranscriptionResult: Sendable {
    /// Recognized text (`bestTranscription.formattedString`).
    let text: String
    /// Mean word-level confidence (0.0 – 1.0).
    let confidence: Float
    /// Locale used for recognition.
    let locale: Locale
    /// Wall-clock time when speech started (from `SpeechSegment.capturedAt`).
    let capturedAt: Date
    /// Duration of the audio that was recognized, in seconds.
    let audioDuration: TimeInterval
}

// MARK: - STTError

enum STTError: LocalizedError {
    case permissionDenied
    case recognizerUnavailable(Locale)
    case recognitionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Speech recognition permission denied. Enable in System Settings > Privacy > Speech Recognition."
        case .recognizerUnavailable(let locale):
            return "Speech recognizer unavailable for \(locale.identifier). Ensure a language model is installed."
        case .recognitionFailed(let error):
            return "Speech recognition failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - STTConfiguration

struct STTConfiguration: Sendable {
    /// Minimum mean word confidence to emit a result (0.0 – 1.0). Default: 0.60.
    var minimumConfidence: Float = 0.60
    /// Prefer on-device recognition when the locale supports it. Default: true.
    var preferOnDevice: Bool = true

    // nonisolated(unsafe): immutable Sendable value; safe under SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor
    nonisolated(unsafe) static let `default` = STTConfiguration()
}

// MARK: - SpeechRecognizerService

/// Actor-based speech recognition protocol.
///
/// `transcriptionStream` and `locale` are `nonisolated` — initialized in `init()`
/// before any async work, safe to access without `await` from any context.
protocol SpeechRecognizerService: Actor {
    /// Emitted `TranscriptionResult`s with confidence ≥ threshold.
    nonisolated var transcriptionStream: AsyncStream<TranscriptionResult> { get }
    /// Currently configured locale.
    nonisolated var locale: Locale { get }

    /// Begin consuming speech segments from VAD. Throws on permission/availability error.
    func activate(stream: AsyncStream<SpeechSegment>) async throws
    /// Stop processing. In-flight recognition is cancelled; no further output.
    func deactivate() async
    /// Switch to a different recognition locale.
    func setLocale(_ locale: Locale) async
}
