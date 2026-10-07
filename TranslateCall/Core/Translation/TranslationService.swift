import Foundation

// MARK: - TranslationError

enum TranslationError: LocalizedError, Equatable {
    case sessionError(Error)
    case timedOut
    case unsupportedPair(Locale.Language, Locale.Language)
    case networkUnavailable
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .sessionError(let error):
            return "Translation failed: \(error.localizedDescription)"
        case .timedOut:
            return "Translation took too long."
        case .unsupportedPair(let source, let target):
            return "Translation from \(source.minimalIdentifier) to \(target.minimalIdentifier) is not supported."
        case .networkUnavailable:
            return "Translation requires a network connection but none is available."
        case .modelNotLoaded:
            return "Translation model is not loaded. Download it first."
        }
    }

    static func == (lhs: TranslationError, rhs: TranslationError) -> Bool {
        switch (lhs, rhs) {
        case (.sessionError, .sessionError): return true
        case (.timedOut, .timedOut): return true
        case (.unsupportedPair(let lSrc, let lTgt), .unsupportedPair(let rSrc, let rTgt)):
            return lSrc == rSrc && lTgt == rTgt
        case (.networkUnavailable, .networkUnavailable): return true
        case (.modelNotLoaded, .modelNotLoaded): return true
        default: return false
        }
    }
}

// MARK: - TranslationService

protocol TranslationService: AnyObject {
    var engineName: String { get }
    func translate(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String
    /// Opens the session for a pair ahead of the first sentence (F8.5.4 REQ-TR-05). Must return at once.
    func warmUp(from source: Locale.Language, to target: Locale.Language) async
    func supports(source: Locale.Language, target: Locale.Language) async -> Bool
}

extension TranslationService {
    var engineName: String { "Unknown" }
    func warmUp(from source: Locale.Language, to target: Locale.Language) async {}
    func supports(source: Locale.Language, target: Locale.Language) async -> Bool { true }
}
