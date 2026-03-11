import FluidAudio
import Foundation

// MARK: - ParakeetTranscriptionOutput

/// Result returned by `AsrTranscriber.transcribeAudio`.
///
/// Using a named struct instead of a 3-member tuple satisfies SwiftLint's
/// `large_tuple` rule and makes call sites more readable.
struct ParakeetTranscriptionOutput: Sendable {
    let text: String
    let confidence: Float
    let duration: TimeInterval
}

// MARK: - AsrTranscriber

/// Minimal abstraction over `AsrManager` so `ParakeetSpeechService` can be
/// tested without loading a real CoreML model.
///
/// Only the methods used by the service are exposed here;
/// `AsrManager` satisfies this protocol via the extension below.
protocol AsrTranscriber: Sendable {
    /// Transcribe 16 kHz mono Float32 samples and return text, confidence, and audio duration.
    func transcribeAudio(_ samples: [Float]) async throws -> ParakeetTranscriptionOutput

    /// Release underlying model resources. Default implementation is a no-op.
    nonisolated func cleanup()
}

extension AsrTranscriber {
    nonisolated func cleanup() {}
}

// MARK: - AsrManager conformance

// @unchecked Sendable: AsrManager is a class from FluidAudio designed for async, concurrent use.
// Its internal CoreML inference state is protected by Swift's structured concurrency + actor isolation
// in ParakeetSpeechService. The same pattern is used for AVAudioPCMBuffer elsewhere in this project.
extension AsrManager: @unchecked @retroactive Sendable {}

extension AsrManager: AsrTranscriber {
    func transcribeAudio(_ samples: [Float]) async throws -> ParakeetTranscriptionOutput {
        let result = try await transcribe(samples, source: .microphone)
        return ParakeetTranscriptionOutput(
            text: result.text,
            confidence: result.confidence,
            duration: result.duration
        )
    }
}
