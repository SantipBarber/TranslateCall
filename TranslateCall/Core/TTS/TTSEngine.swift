import Foundation

// MARK: - TTSEngine

/// Available TTS engines.
///
/// Mirrors the `STTEngine` pattern from F6.1.
/// `avSpeech` supports all languages; `kokoro` is English-only (American English, beta).
/// `voiceClone` uses Qwen3-TTS for voice-cloned synthesis (10 languages).
enum TTSEngine: String, Codable, Sendable, CaseIterable {
    case avSpeech
    case kokoro
    case voiceClone
    case edgeTTS

    nonisolated var displayName: String {
        switch self {
        case .avSpeech:   return "AVSpeech"
        case .kokoro:     return "Kokoro"
        case .voiceClone: return "Voice Clone"
        case .edgeTTS:    return "Edge TTS (Cloud)"
        }
    }

    /// Returns true if this engine can synthesise for the given locale.
    nonisolated func supports(locale: Locale) -> Bool {
        switch self {
        case .avSpeech:   return true
        case .kokoro:     return locale.isEnglish
        case .voiceClone: return QwenCloneConfiguration.supportsLocale(locale)
        case .edgeTTS:    return EdgeTTSVoiceCatalog.supports(locale)
        }
    }
}
