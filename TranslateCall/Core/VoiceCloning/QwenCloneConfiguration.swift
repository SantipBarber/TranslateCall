import Foundation

// MARK: - QwenCloneConfiguration

/// Configuration for Qwen3-TTS voice cloning.
nonisolated struct QwenCloneConfiguration: Sendable {
    var modelRepo: String = "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
    var maxTokens: Int = 2048
    var temperature: Float = 0.7
    var topP: Float = 0.95
    var repetitionPenalty: Float = 1.5
    var inferenceTimeoutSeconds: Int = 10
    var textTruncationLimit: Int = 200

    nonisolated(unsafe) static let `default` = QwenCloneConfiguration()

    static let voiceCloningEnabledKey = "tlk.voiceCloning.enabled"

    // MARK: - Supported languages

    private static let languageMap: [String: String] = [
        "en": "english",
        "es": "spanish",
        "fr": "french",
        "de": "german",
        "it": "italian",
        "pt": "portuguese",
        "ru": "russian",
        "zh": "chinese",
        "ja": "japanese",
        "ko": "korean"
    ]

    /// Maps Locale to Qwen3-TTS language string. Returns nil for unsupported locales.
    static func language(for locale: Locale) -> String? {
        let code = locale.language.languageCode?.identifier ?? ""
        return languageMap[code]
    }

    /// Returns true if the locale is supported for voice cloning.
    static func supportsLocale(_ locale: Locale) -> Bool {
        language(for: locale) != nil
    }

    /// Number of supported languages.
    static var supportedLanguageCount: Int {
        languageMap.count
    }
}

// MARK: - QwenCloneError

enum QwenCloneError: Error, Sendable {
    case modelNotReady
    case inferenceTimeout
    case downloadFailed(String)
    case unsupportedLocale
}
