import AVFoundation
import Foundation

// MARK: - SystemVoicePreference

/// The Apple voice picked per language in Settings › Voices (REQ-ST-22); "" or absent = Automatic.
nonisolated enum SystemVoicePreference {
    static func key(for languageCode: String) -> String { "tlk.tts.systemVoice.\(languageCode)" }

    static func identifier(for locale: Locale, defaults: UserDefaults = .standard) -> String? {
        guard let code = locale.language.languageCode?.identifier,
              let id = defaults.string(forKey: key(for: code)), !id.isEmpty else { return nil }
        return id
    }

    static func set(_ identifier: String?, for languageCode: String, defaults: UserDefaults = .standard) {
        defaults.set(identifier ?? "", forKey: key(for: languageCode))
    }
}

// MARK: - StandardVoices

/// An installed system voice, as plain values so the picker logic is testable.
nonisolated struct SystemVoice: Equatable, Sendable {
    let identifier: String
    let name: String
    /// BCP-47, e.g. `de-DE`.
    let language: String
    /// 1 default, 2 enhanced, 3 premium (`AVSpeechSynthesisVoiceQuality` raw values).
    let quality: Int

    static var installed: [SystemVoice] {
        AVSpeechSynthesisVoice.speechVoices().map {
            SystemVoice(identifier: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality.rawValue)
        }
    }
}

/// One entry of a "Standard voice for <language>" picker.
nonisolated struct VoiceOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

/// The options of the standard voice picker per engine (REQ-ST-22).
nonisolated enum StandardVoices {
    static let automatic = VoiceOption(id: "", name: String(localized: "Automatic"))

    /// Automatic, then the installed voices of the language, best quality first, then by name.
    static func appleOptions(for locale: Locale, installed: [SystemVoice]) -> [VoiceOption] {
        let code = locale.language.languageCode?.identifier ?? ""
        let voices = installed
            .filter { ($0.language.components(separatedBy: "-").first ?? "") == code }
            .sorted { ($0.quality, $1.name) > ($1.quality, $0.name) }
        return [automatic] + voices.map { VoiceOption(id: $0.identifier, name: label($0)) }
    }

    /// "Anna · Apple", "Anna (Enhanced) · Apple", "Anna (Premium) · Apple".
    static func label(_ voice: SystemVoice) -> String {
        switch voice.quality {
        case 3: "\(voice.name) (Premium) · Apple"
        case 2: "\(voice.name) (Enhanced) · Apple"
        default: "\(voice.name) · Apple"
        }
    }

    /// Kokoro's voices (the legacy picker's list; English only).
    static let kokoroOptions: [VoiceOption] = [
        VoiceOption(id: "", name: "Default (af_heart)"), VoiceOption(id: "af_heart", name: "af_heart"),
        VoiceOption(id: "af_bella", name: "af_bella"), VoiceOption(id: "am_adam", name: "am_adam"),
        VoiceOption(id: "am_michael", name: "am_michael")
    ]

    /// Edge's fixed voice for the language, shown read-only.
    static func edgeVoiceName(for locale: Locale) -> String? {
        EdgeTTSVoiceCatalog.defaultVoice(for: locale)?.friendlyName
    }
}
