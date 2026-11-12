import AVFoundation
import Foundation
import Speech

// MARK: - AVAudioPCMBuffer helpers

extension AVAudioPCMBuffer {
    /// Extracts channel 0 as a `[Float]` array.
    ///
    /// Returns an empty array if the buffer has no float channel data (e.g. non-Float32 format).
    /// Used by `ParakeetSpeechService` to convert a `SpeechSegment` to the flat array
    /// that `AsrManager.transcribe` expects.
    ///
    /// `nonisolated`: called from actor context (ParakeetSpeechService);
    /// `AVAudioPCMBuffer: @unchecked Sendable` — safe under actor isolation.
    nonisolated func toFloatSamples() -> [Float] {
        guard let channelData = floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(frameLength)))
    }
}

// MARK: - TranscriptionResult

/// A speech recognition result for one segment. An empty `text` means "nothing recognized".
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
    /// Id of the `SpeechSegment` this result belongs to (0 for untagged sources).
    var segmentID: UInt64 = 0
    /// Whether the segment was tentative (may be retracted) or final.
    var kind: SegmentKind = .final
    /// What the engine recognized before it dropped the result for low confidence (nil otherwise).
    /// Only the trace reads it (QS-8); the pipeline sees an empty result.
    var dropped: DroppedTranscript?

    /// The result for a segment that produced no usable text (empty transcript, low confidence,
    /// recognition error). Engines yield one for every segment so a downstream committer never
    /// waits for an id that will not come.
    nonisolated static func empty(for segment: SpeechSegment, locale: Locale) -> TranscriptionResult {
        TranscriptionResult(
            text: "", confidence: 0, locale: locale, capturedAt: segment.capturedAt,
            audioDuration: Double(segment.audio.frameLength) / segment.audio.format.sampleRate,
            segmentID: segment.id, kind: segment.kind
        )
    }

    /// An empty result for a recognition dropped below `STTConfiguration.minimumConfidence`.
    nonisolated static func lowConfidence(
        _ text: String, confidence: Float, for segment: SpeechSegment, locale: Locale
    ) -> TranscriptionResult {
        var result = empty(for: segment, locale: locale)
        result.dropped = DroppedTranscript(text: text, confidence: confidence)
        return result
    }

    /// The same segment with no text: the committer skips it without blocking the head.
    nonisolated func droppingText() -> TranscriptionResult {
        TranscriptionResult(
            text: "", confidence: 0, locale: locale, capturedAt: capturedAt, audioDuration: audioDuration,
            segmentID: segmentID, kind: kind, dropped: dropped
        )
    }
}

/// A recognition the engine dropped because its confidence was under the floor.
struct DroppedTranscript: Sendable, Equatable {
    let text: String
    let confidence: Float
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

    nonisolated static let `default` = STTConfiguration()
}

// MARK: - SpeechRecognizerService

/// Actor-based speech recognition protocol.
///
/// `transcriptionStream` and `locale` are `nonisolated` — initialized in `init()`
/// before any async work, safe to access without `await` from any context.
protocol SpeechRecognizerService: Actor {
    /// One `TranscriptionResult` per segment; empty text when nothing usable was recognized.
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
