import Foundation

// MARK: - TranslationError

enum TranslationError: LocalizedError, Equatable {
    case bridgeUnavailable
    case sessionError(Error)
    case unsupportedPair(Locale.Language, Locale.Language)
    case networkUnavailable
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .bridgeUnavailable:
            return "Translation bridge is unavailable. Restart the app."
        case .sessionError(let error):
            return "Translation failed: \(error.localizedDescription)"
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
        case (.bridgeUnavailable, .bridgeUnavailable): return true
        case (.sessionError, .sessionError): return true
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
    func prepare(source: Locale.Language, target: Locale.Language) async throws
    func supports(source: Locale.Language, target: Locale.Language) async -> Bool
}

extension TranslationService {
    var engineName: String { "Unknown" }
    func supports(source: Locale.Language, target: Locale.Language) async -> Bool { true }
}
