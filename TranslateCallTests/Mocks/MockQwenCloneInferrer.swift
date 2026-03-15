import Foundation
@testable import TranslateCall

// MARK: - MockQwenCloneInferrer

/// Test mock for `QwenCloneInferring`. Tracks calls and returns configurable stubs.
actor MockQwenCloneInferrer: QwenCloneInferring {

    nonisolated let sampleRate: Int = 24_000

    // MARK: - Stubs

    private var stubSamples: [Float] = Array(repeating: 0.1, count: 2400)
    private var stubError: Error?
    private var stubDelay: Duration?

    // MARK: - Tracking

    private(set) var callCount: Int = 0
    private(set) var lastText: String?
    private(set) var lastLanguage: String?
    private(set) var lastReferenceAudioCount: Int = 0

    // MARK: - Configuration

    func setStubSamples(_ samples: [Float]) {
        stubSamples = samples
    }

    func setStubError(_ error: Error?) {
        stubError = error
    }

    func setStubDelay(_ delay: Duration?) {
        stubDelay = delay
    }

    // MARK: - QwenCloneInferring

    func synthesize(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) async throws -> [Float] {
        callCount += 1
        lastText = text
        lastLanguage = language
        lastReferenceAudioCount = referenceAudio.count

        if let delay = stubDelay {
            try await Task.sleep(for: delay)
        }

        if let error = stubError {
            throw error
        }

        return stubSamples
    }
}
