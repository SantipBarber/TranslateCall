import Foundation

// MARK: - EdgeTTSVoice

struct EdgeTTSVoice: Sendable, Codable {
    let shortName: String
    let locale: String
    let gender: String
    let friendlyName: String
}

// MARK: - EdgeTTSVoiceCatalog

/// Static catalog of Microsoft Edge TTS neural voices.
/// Covers languages missing from AVSpeechSynthesizer and major world languages.
enum EdgeTTSVoiceCatalog {
    nonisolated static let voices: [EdgeTTSVoice] = [
        // Ukrainian
        EdgeTTSVoice(shortName: "uk-UA-PolinaNeural", locale: "uk-UA", gender: "Female", friendlyName: "Polina"),
        EdgeTTSVoice(shortName: "uk-UA-OstapNeural", locale: "uk-UA", gender: "Male", friendlyName: "Ostap"),
        // Arabic
        EdgeTTSVoice(shortName: "ar-SA-ZariyahNeural", locale: "ar-SA", gender: "Female", friendlyName: "Zariyah"),
        EdgeTTSVoice(shortName: "ar-SA-HamedNeural", locale: "ar-SA", gender: "Male", friendlyName: "Hamed"),
        // Bengali
        EdgeTTSVoice(shortName: "bn-IN-TanishaaNeural", locale: "bn-IN", gender: "Female", friendlyName: "Tanishaa"),
        // Chinese (Mandarin)
        EdgeTTSVoice(shortName: "zh-CN-XiaoxiaoNeural", locale: "zh-CN", gender: "Female", friendlyName: "Xiaoxiao"),
        EdgeTTSVoice(shortName: "zh-CN-YunxiNeural", locale: "zh-CN", gender: "Male", friendlyName: "Yunxi"),
        // Dutch
        EdgeTTSVoice(shortName: "nl-NL-ColetteNeural", locale: "nl-NL", gender: "Female", friendlyName: "Colette"),
        // English
        EdgeTTSVoice(shortName: "en-US-JennyNeural", locale: "en-US", gender: "Female", friendlyName: "Jenny"),
        EdgeTTSVoice(shortName: "en-US-GuyNeural", locale: "en-US", gender: "Male", friendlyName: "Guy"),
        EdgeTTSVoice(shortName: "en-GB-SoniaNeural", locale: "en-GB", gender: "Female", friendlyName: "Sonia"),
        // French
        EdgeTTSVoice(shortName: "fr-FR-DeniseNeural", locale: "fr-FR", gender: "Female", friendlyName: "Denise"),
        EdgeTTSVoice(shortName: "fr-FR-HenriNeural", locale: "fr-FR", gender: "Male", friendlyName: "Henri"),
        // German
        EdgeTTSVoice(shortName: "de-DE-KatjaNeural", locale: "de-DE", gender: "Female", friendlyName: "Katja"),
        EdgeTTSVoice(shortName: "de-DE-ConradNeural", locale: "de-DE", gender: "Male", friendlyName: "Conrad"),
        // Hindi
        EdgeTTSVoice(shortName: "hi-IN-SwaraNeural", locale: "hi-IN", gender: "Female", friendlyName: "Swara"),
        // Indonesian
        EdgeTTSVoice(shortName: "id-ID-GadisNeural", locale: "id-ID", gender: "Female", friendlyName: "Gadis"),
        // Italian
        EdgeTTSVoice(shortName: "it-IT-ElsaNeural", locale: "it-IT", gender: "Female", friendlyName: "Elsa"),
        // Japanese
        EdgeTTSVoice(shortName: "ja-JP-NanamiNeural", locale: "ja-JP", gender: "Female", friendlyName: "Nanami"),
        // Korean
        EdgeTTSVoice(shortName: "ko-KR-SunHiNeural", locale: "ko-KR", gender: "Female", friendlyName: "SunHi"),
        // Polish
        EdgeTTSVoice(shortName: "pl-PL-AgnieszkaNeural", locale: "pl-PL", gender: "Female", friendlyName: "Agnieszka"),
        // Portuguese (Brazil)
        EdgeTTSVoice(shortName: "pt-BR-FranciscaNeural", locale: "pt-BR", gender: "Female", friendlyName: "Francisca"),
        // Portuguese (Portugal)
        EdgeTTSVoice(shortName: "pt-PT-RaquelNeural", locale: "pt-PT", gender: "Female", friendlyName: "Raquel"),
        // Russian
        EdgeTTSVoice(shortName: "ru-RU-SvetlanaNeural", locale: "ru-RU", gender: "Female", friendlyName: "Svetlana"),
        EdgeTTSVoice(shortName: "ru-RU-DmitryNeural", locale: "ru-RU", gender: "Male", friendlyName: "Dmitry"),
        // Spanish
        EdgeTTSVoice(shortName: "es-ES-ElviraNeural", locale: "es-ES", gender: "Female", friendlyName: "Elvira"),
        EdgeTTSVoice(shortName: "es-MX-DaliaNeural", locale: "es-MX", gender: "Female", friendlyName: "Dalia"),
        // Swedish
        EdgeTTSVoice(shortName: "sv-SE-SofieNeural", locale: "sv-SE", gender: "Female", friendlyName: "Sofie"),
        // Thai
        EdgeTTSVoice(shortName: "th-TH-PremwadeeNeural", locale: "th-TH", gender: "Female", friendlyName: "Premwadee"),
        // Turkish
        EdgeTTSVoice(shortName: "tr-TR-EmelNeural", locale: "tr-TR", gender: "Female", friendlyName: "Emel"),
        // Vietnamese
        EdgeTTSVoice(shortName: "vi-VN-HoaiMyNeural", locale: "vi-VN", gender: "Female", friendlyName: "HoaiMy"),
        // Catalan
        EdgeTTSVoice(shortName: "ca-ES-JoanaNeural", locale: "ca-ES", gender: "Female", friendlyName: "Joana"),
        // Czech
        EdgeTTSVoice(shortName: "cs-CZ-VlastaNeural", locale: "cs-CZ", gender: "Female", friendlyName: "Vlasta"),
        // Danish
        EdgeTTSVoice(shortName: "da-DK-ChristelNeural", locale: "da-DK", gender: "Female", friendlyName: "Christel"),
        // Finnish
        EdgeTTSVoice(shortName: "fi-FI-SelmaNeural", locale: "fi-FI", gender: "Female", friendlyName: "Selma"),
        // Greek
        EdgeTTSVoice(shortName: "el-GR-AthinaNeural", locale: "el-GR", gender: "Female", friendlyName: "Athina"),
        // Hebrew
        EdgeTTSVoice(shortName: "he-IL-HilaNeural", locale: "he-IL", gender: "Female", friendlyName: "Hila"),
        // Hungarian
        EdgeTTSVoice(shortName: "hu-HU-NoemiNeural", locale: "hu-HU", gender: "Female", friendlyName: "Noemi"),
        // Malay
        EdgeTTSVoice(shortName: "ms-MY-YasminNeural", locale: "ms-MY", gender: "Female", friendlyName: "Yasmin"),
        // Norwegian
        EdgeTTSVoice(shortName: "nb-NO-PernilleNeural", locale: "nb-NO", gender: "Female", friendlyName: "Pernille"),
        // Romanian
        EdgeTTSVoice(shortName: "ro-RO-AlinaNeural", locale: "ro-RO", gender: "Female", friendlyName: "Alina"),
        // Slovak
        EdgeTTSVoice(shortName: "sk-SK-ViktoriaNeural", locale: "sk-SK", gender: "Female", friendlyName: "Viktoria")
    ]

    /// Returns all voices matching the given locale's language code.
    nonisolated static func availableVoices(for locale: Locale) -> [EdgeTTSVoice] {
        guard let code = locale.language.languageCode?.identifier else { return [] }
        return voices.filter { $0.locale.hasPrefix(code) }
    }

    /// Returns the default (first) voice for a locale, or nil if unsupported.
    nonisolated static func defaultVoice(for locale: Locale) -> EdgeTTSVoice? {
        availableVoices(for: locale).first
    }

    /// Returns true if Edge TTS has at least one voice for this locale.
    nonisolated static func supports(_ locale: Locale) -> Bool {
        defaultVoice(for: locale) != nil
    }
}
