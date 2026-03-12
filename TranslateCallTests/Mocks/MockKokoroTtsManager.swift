import Foundation
@testable import TranslateCall

// MARK: - MockKokoroTtsManager

/// Test double for `KokoroTtsManaging`.
///
/// Allows tests to control synthesis output without loading any CoreML model.
/// All state is actor-isolated; use `await mock.stubResult(...)` from test bodies.
actor MockKokoroTtsManager: KokoroTtsManaging {

    // MARK: - Observation

    private(set) var callCount: Int = 0
    private(set) var receivedTexts: [String] = []

    // MARK: - Stubs

    private var stubbedSamples: [Float] = [0.1, 0.2, 0.3]
    private var stubbedError: Error?

    // MARK: - Configuration

    func stubResult(_ samples: [Float]) {
        stubbedSamples = samples
        stubbedError = nil
    }

    func stubError(_ error: Error) {
        stubbedError = error
    }

    func reset() {
        callCount = 0
        receivedTexts = []
        stubbedSamples = [0.1, 0.2, 0.3]
        stubbedError = nil
    }

    // MARK: - KokoroTtsManaging

    func synthesizeSamples(text: String, voice: String?) async throws -> [Float] {
        callCount += 1
        receivedTexts.append(text)
        if let error = stubbedError { throw error }
        return stubbedSamples
    }
}
