import Foundation
@testable import TranslateCall

// MARK: - MockAsrTranscriber

/// Test double for `AsrTranscriber`.
///
/// Allows tests to control the transcription result and error without loading any CoreML model.
/// All state is actor-isolated; use `await mock.stubResult(...)` from test bodies.
actor MockAsrTranscriber: AsrTranscriber {

    // MARK: - Observation

    private(set) var callCount: Int = 0
    private(set) var receivedSamples: [[Float]] = []

    // MARK: - Stubs

    private var stubbedOutput = ParakeetTranscriptionOutput(text: "mock transcription", confidence: 0.9, duration: 1.0)
    private var stubbedError: Error?

    // MARK: - Configuration

    func stubResult(text: String, confidence: Float = 0.9, duration: TimeInterval = 1.0) {
        stubbedOutput = ParakeetTranscriptionOutput(text: text, confidence: confidence, duration: duration)
        stubbedError = nil
    }

    func stubError(_ error: Error) {
        stubbedError = error
    }

    func clearError() {
        stubbedError = nil
    }

    func reset() {
        callCount = 0
        receivedSamples = []
        stubbedOutput = ParakeetTranscriptionOutput(text: "mock transcription", confidence: 0.9, duration: 1.0)
        stubbedError = nil
    }

    // MARK: - AsrTranscriber

    func transcribeAudio(_ samples: [Float]) async throws -> ParakeetTranscriptionOutput {
        callCount += 1
        receivedSamples.append(samples)
        if let error = stubbedError { throw error }
        return stubbedOutput
    }
}
