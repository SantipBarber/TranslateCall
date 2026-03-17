import Foundation

/// Actor-based implementation of `TranslationService` using Apple's Translation framework
/// via `TranslationBridgeModel`. Each call suspends until the SwiftUI bridge delivers
/// a `TranslationSession` and completes the operation.
actor AppleTranslationService: TranslationService {
    // nonisolated(unsafe): weak reference to a @MainActor object read from actor context.
    // Captured once per call before hopping to @MainActor — safe by design.
    nonisolated(unsafe) private weak var model: TranslationBridgeModel?

    init(model: TranslationBridgeModel) {
        self.model = model
    }

    // MARK: - TranslationService

    nonisolated var engineName: String { "Apple Translation" }

    func translate(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let capturedModel = model
            Task { @MainActor in
                guard let model = capturedModel else {
                    continuation.resume(throwing: TranslationError.bridgeUnavailable)
                    return
                }
                model.enqueue(.translate(text: text, continuation: continuation), from: source, to: target)
            }
        }
    }

    func prepare(source: Locale.Language, target: Locale.Language) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let capturedModel = model
            Task { @MainActor in
                guard let model = capturedModel else {
                    continuation.resume(throwing: TranslationError.bridgeUnavailable)
                    return
                }
                model.enqueue(.prepare(continuation: continuation), from: source, to: target)
            }
        }
    }
}
