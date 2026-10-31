import Foundation

// MARK: - GuidedReadingTexts

/// Passages the user reads aloud to record a short voice-clone reference (REQ-QS-12/13).
///
/// Neutral, phonetically varied, with no digits, abbreviations or names. Each is sized for about
/// `QwenCloneConfiguration.guidedTargetSeconds` at a calm pace (~2.5 words/s; ~5 characters/s for
/// Chinese, Japanese and Korean). Keys match `QwenCloneConfiguration.supportedLanguageList`.
nonisolated enum GuidedReadingTexts {
    private static let texts: [String: String] = [
        "english": "Good morning. I am recording my voice so the application can speak like me "
            + "when I talk with other people.",
        "spanish": "Buenos días. Estoy grabando mi voz para que la aplicación pueda hablar como yo "
            + "cuando converso con otras personas.",
        "french": "Bonjour. J'enregistre ma voix pour que l'application puisse parler comme moi "
            + "quand je discute avec d'autres personnes.",
        "german": "Guten Tag. Ich nehme meine Stimme auf, damit die Anwendung wie ich sprechen kann, "
            + "wenn ich mit anderen Menschen rede.",
        "italian": "Buongiorno. Sto registrando la mia voce perché l'applicazione possa parlare come me "
            + "quando parlo con altre persone.",
        "portuguese": "Bom dia. Estou gravando a minha voz para que o aplicativo possa falar como eu "
            + "quando converso com outras pessoas.",
        "russian": "Доброе утро. Я записываю свой голос, чтобы приложение могло говорить как я, "
            + "когда я общаюсь с другими людьми.",
        "chinese": "早上好。我正在录制我的声音，这样应用就能在我和别人交谈的时候，像我一样说话。",
        "japanese": "おはようございます。私が他の人と話すときに、アプリが私のように話せるよう、自分の声を録音しています。",
        "korean": "안녕하세요. 제 목소리를 녹음하고 있어요. 다른 사람들과 대화할 때 앱이 저처럼 말할 수 있도록 녹음해요."
    ]

    /// The passage to read for a Qwen language key; English for an unknown one.
    static func text(for language: String) -> String {
        texts[language] ?? texts["english"] ?? ""
    }
}
