import Foundation

// MARK: - TTSEngine

/// Available TTS engines.
///
/// Mirrors the `STTEngine` pattern from F6.1.
/// `avSpeech` supports all languages; `kokoro` is English-only (American English, beta).
enum TTSEngine: String, Codable, Sendable, CaseIterable {
    case avSpeech
    case kokoro

    var displayName: String {
        switch self {
        case .avSpeech: return "AVSpeech"
        case .kokoro:   return "Kokoro"
        }
    }

    /// Returns true if this engine can synthesise for the given locale.
    func supports(locale: Locale) -> Bool {
        switch self {
        case .avSpeech: return true
        case .kokoro:   return locale.isEnglish
        }
    }
}
