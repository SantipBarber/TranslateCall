import Foundation

// MARK: - STTEngine

/// Available speech-to-text engines.
enum STTEngine: String, Codable, Sendable, CaseIterable {
    /// Apple SFSpeechRecognizer — supports all installed languages.
    case appleSpeech
    /// FluidAudio Parakeet TDT v3 — English only, higher accuracy on-device.
    case parakeet

    /// nonisolated: pure computed value, no shared mutable state.
    nonisolated var displayName: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .parakeet:    "Parakeet (Enhanced)"
        }
    }

    /// True when this engine can handle the given locale.
    ///
    /// `appleSpeech` returns `true` for every locale (availability is checked at runtime
    /// via `SFSpeechRecognizer.isAvailable`). `parakeet` only supports `en-*` locales.
    ///
    /// `nonisolated`: pure function, called from actor contexts and test bodies.
    nonisolated func supports(locale: Locale) -> Bool {
        switch self {
        case .appleSpeech: true
        case .parakeet:    locale.isEnglish
        }
    }
}

// MARK: - Locale helpers

extension Locale {
    /// `true` when the locale's BCP-47 primary language subtag is `"en"`.
    ///
    /// `nonisolated`: called from actor contexts (ParakeetSpeechService, STTEngine.supports);
    /// `Locale` is a Sendable value type so there is no data-race risk.
    nonisolated var isEnglish: Bool {
        language.languageCode?.identifier == "en"
    }
}
