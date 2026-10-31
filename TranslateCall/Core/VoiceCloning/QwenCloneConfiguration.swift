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
    /// Qwen3-TTS (12 Hz codec) output rate, as `QwenCloneClient.sampleRate` reports it.
    var outputSampleRate: Int = 24_000
    /// Seconds of audio between streamed chunks (mlx-audio `streamingInterval`).
    var streamingInterval: Double = 0.32
    /// How long a streamed synthesis may take to produce its first audio chunk.
    var firstChunkTimeoutSeconds: Double = 3

    nonisolated static let `default` = QwenCloneConfiguration()

    // MARK: - Reference recording (REQ-QS-12/13)

    /// Length of the guided reading (user pick P-1).
    static let guidedTargetSeconds: Double = 8
    /// Longest guided recording before it stops by itself.
    static let guidedMaxSeconds: Double = 15
    /// Longest free recording.
    static let freeMaxSeconds: Double = 30
    /// A reference longer than this is considered long (slower to prefill).
    static let longReferenceSeconds: Double = 12

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

    // MARK: - Language list for UI

    /// Language entries for picker UI: (key: Qwen language string, label: display name).
    static let supportedLanguageList: [(key: String, label: String)] = [
        ("english", "English"),
        ("spanish", "Spanish"),
        ("french", "French"),
        ("german", "German"),
        ("italian", "Italian"),
        ("portuguese", "Portuguese"),
        ("russian", "Russian"),
        ("chinese", "Chinese"),
        ("japanese", "Japanese"),
        ("korean", "Korean")
    ]

    // MARK: - Demo text

    private static let demoTexts: [String: String] = [
        "english": "Hello, this is a preview of my cloned voice.",
        "spanish": "Hola, esta es una vista previa de mi voz clonada.",
        "french": "Bonjour, ceci est un aperçu de ma voix clonée.",
        "german": "Hallo, dies ist eine Vorschau meiner geklonten Stimme.",
        "italian": "Ciao, questa è un'anteprima della mia voce clonata.",
        "portuguese": "Olá, esta é uma prévia da minha voz clonada.",
        "russian": "Здравствуйте, это предварительный просмотр моего клонированного голоса.",
        "chinese": "你好，这是我克隆声音的预览。",
        "japanese": "こんにちは、これは私のクローン音声のプレビューです。",
        "korean": "안녕하세요, 제 복제된 목소리의 미리보기입니다."
    ]

    /// Localized demo sentence for voice preview.
    static func demoText(for language: String) -> String {
        demoTexts[language] ?? "Hello, this is a preview of my cloned voice."
    }
}

// MARK: - QwenCloneError

nonisolated enum QwenCloneError: LocalizedError, Sendable, Equatable {
    case modelNotReady
    case inferenceTimeout
    case downloadFailed(String)
    case unsupportedLocale
    /// Another Qwen inference held `MLXInferenceGate` longer than the wait limit (F8.5.2 REQ-T-32).
    case gateBusy
    /// The model returned no audio.
    case emptyOutput
    /// A previous streamed sentence nobody listens to any more still holds the model.
    case gateBusyAbandoned

    var errorDescription: String? {
        switch self {
        case .modelNotReady: return "The voice clone model is not loaded."
        case .inferenceTimeout: return "Voice clone synthesis took too long."
        case .downloadFailed(let reason): return "Voice clone model download failed: \(reason)"
        case .unsupportedLocale: return "Voice clone does not support this language."
        case .gateBusy: return "The voice clone model is busy. Try again in a moment."
        case .emptyOutput: return "Voice clone synthesis produced no audio."
        case .gateBusyAbandoned: return "The voice clone model is finishing a previous sentence."
        }
    }
}

extension QwenCloneError: TTSAttemptError {
    /// An abandoned generation still holds the gate: not the clone's fault, so the breaker ignores it.
    nonisolated var countsTowardBreaker: Bool { self != .gateBusyAbandoned }
}
