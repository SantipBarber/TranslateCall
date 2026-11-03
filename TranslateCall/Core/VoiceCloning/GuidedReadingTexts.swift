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
            + "when I talk with other people. I read calmly, with a short breath between sentences.",
        "spanish": "Buenos días. Estoy grabando mi voz para que la aplicación pueda hablar como yo "
            + "cuando converso con otras personas. Leo con calma, con una pequeña pausa entre frases.",
        "french": "Bonjour. J'enregistre ma voix pour que l'application puisse parler comme moi "
            + "quand je discute avec d'autres personnes. Je lis calmement, avec une petite pause entre les phrases.",
        "german": "Guten Tag. Ich nehme meine Stimme auf, damit die Anwendung wie ich sprechen kann, "
            + "wenn ich mit anderen Menschen rede. Ich lese ruhig, mit einer kurzen Pause zwischen den Sätzen.",
        "italian": "Buongiorno. Sto registrando la mia voce perché l'applicazione possa parlare come me "
            + "quando parlo con altre persone. Leggo con calma, con una breve pausa tra una frase e l'altra.",
        "portuguese": "Bom dia. Estou gravando a minha voz para que o aplicativo possa falar como eu "
            + "quando converso com outras pessoas. Leio com calma, com uma pequena pausa entre as frases.",
        "russian": "Доброе утро. Я записываю свой голос, чтобы приложение могло говорить как я, "
            + "когда я общаюсь с другими людьми. Я читаю спокойно, с небольшой паузой между фразами.",
        "chinese": "早上好。我正在录制我的声音，这样应用就能在我和别人交谈的时候，像我一样说话。"
            + "我会慢慢地、清楚地读，每句话之间稍微停一下。",
        "japanese": "おはようございます。人と話すときに、アプリが私のように話せるように、声を録音しています。"
            + "ゆっくり、はっきり読みます。",
        "korean": "안녕하세요. 제 목소리를 녹음하고 있어요. 다른 사람들과 대화할 때 앱이 저처럼 말할 수 있게 하려고요. "
            + "천천히 또박또박 읽을게요."
    ]

    /// The passage to read for a Qwen language key; English for an unknown one.
    static func text(for language: String) -> String {
        texts[language] ?? texts["english"] ?? ""
    }
}
