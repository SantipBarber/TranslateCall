import Foundation

// MARK: - WhisperLanguages

/// Whisper language support lookup. Based on OpenAI Whisper large-v3 (99 languages).
enum WhisperLanguages {
    nonisolated static let supported: Set<String> = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
        "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
        "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw",
        "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
        "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo",
        "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
        "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
        "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
        "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
        "tr", "tt", "uk", "ur", "uz", "vi", "yi", "yo", "zh", "yue"
    ]

    /// Returns true if Whisper supports the given locale's language.
    nonisolated static func supports(_ locale: Locale) -> Bool {
        guard let code = whisperCode(for: locale) else { return false }
        return supported.contains(code)
    }

    /// Returns the Whisper language code for a locale, or nil if unsupported.
    nonisolated static func whisperCode(for locale: Locale) -> String? {
        guard let code = locale.language.languageCode?.identifier else {
            return nil
        }
        return supported.contains(code) ? code : nil
    }
}
