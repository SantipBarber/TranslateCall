import Foundation

// MARK: - TranslationError

enum TranslationError: LocalizedError, Equatable {
    case bridgeUnavailable
    case sessionError(Error)
    case unsupportedPair(Locale.Language, Locale.Language)

    var errorDescription: String? {
        switch self {
        case .bridgeUnavailable:
            return "Translation bridge is unavailable. Restart the app."
        case .sessionError(let error):
            return "Translation failed: \(error.localizedDescription)"
        case .unsupportedPair(let source, let target):
            return "Translation from \(source.minimalIdentifier) to \(target.minimalIdentifier) is not supported."
        }
    }

    static func == (lhs: TranslationError, rhs: TranslationError) -> Bool {
        switch (lhs, rhs) {
        case (.bridgeUnavailable, .bridgeUnavailable): return true
        case (.sessionError, .sessionError): return true
        case (.unsupportedPair(let lSrc, let lTgt), .unsupportedPair(let rSrc, let rTgt)):
            return lSrc == rSrc && lTgt == rTgt
        default: return false
        }
    }
}

// MARK: - TranslationService

protocol TranslationService: AnyObject {
    func translate(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String
    func prepare(source: Locale.Language, target: Locale.Language) async throws
}
