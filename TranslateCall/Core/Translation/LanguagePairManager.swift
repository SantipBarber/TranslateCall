import Combine
import Foundation
@preconcurrency import Translation

// MARK: - LanguagePairStatus

enum LanguagePairStatus: Equatable {
    case installed
    case supported
    case unsupported
    case unknown
}

// MARK: - LanguagePairManager

@MainActor
final class LanguagePairManager: ObservableObject {
    @Published private(set) var sourceLanguage: Locale.Language
    @Published private(set) var targetLanguage: Locale.Language
    @Published private(set) var pairStatus: LanguagePairStatus = .unknown
    @Published private(set) var supportedLanguages: [Locale.Language] = []
    @Published private(set) var isCheckingAvailability = false

    private let defaults: UserDefaults
    private let languageLoader: (() async -> [Locale.Language])?
    private static let sourceKey = "tlk.source.language"
    private static let targetKey = "tlk.target.language"

    init(defaults: UserDefaults = .standard, languageLoader: (() async -> [Locale.Language])? = nil) {
        self.defaults = defaults
        self.languageLoader = languageLoader

        let currentLang = Locale.current.language
        let isCurrentEnglish = currentLang.languageCode?.identifier == "en"
        let defaultTarget = Locale.Language(identifier: isCurrentEnglish ? "es" : "en")

        sourceLanguage = defaults.string(forKey: Self.sourceKey)
            .map { Locale.Language(identifier: $0) } ?? currentLang
        targetLanguage = defaults.string(forKey: Self.targetKey)
            .map { Locale.Language(identifier: $0) } ?? defaultTarget

        Task {
            await loadSupportedLanguages()
            await checkAvailability()
        }
    }

    // MARK: - Public actions

    func setSourceLanguage(_ lang: Locale.Language) async {
        sourceLanguage = lang
        defaults.set(lang.minimalIdentifier, forKey: Self.sourceKey)
        await checkAvailability()
    }

    func setTargetLanguage(_ lang: Locale.Language) async {
        targetLanguage = lang
        defaults.set(lang.minimalIdentifier, forKey: Self.targetKey)
        await checkAvailability()
    }

    func swapLanguages() async {
        let (src, tgt) = (sourceLanguage, targetLanguage)
        sourceLanguage = tgt
        targetLanguage = src
        defaults.set(tgt.minimalIdentifier, forKey: Self.sourceKey)
        defaults.set(src.minimalIdentifier, forKey: Self.targetKey)
        await checkAvailability()
    }

    func checkAvailability() async {
        isCheckingAvailability = true
        defer { isCheckingAvailability = false }
        let status = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
        pairStatus = LanguagePairStatus(from: status)
    }

    // MARK: - Display names

    func displayName(for language: Locale.Language) -> String {
        Locale.current.localizedString(forLanguageCode: language.languageCode?.identifier ?? "")
            ?? language.minimalIdentifier
    }

    // MARK: - Private

    private func loadSupportedLanguages() async {
        let langs: [Locale.Language]
        if let loader = languageLoader {
            langs = await loader()
        } else {
            langs = await LanguageAvailability().supportedLanguages
        }
        supportedLanguages = langs.sorted { displayName(for: $0) < displayName(for: $1) }
        if !supportedLanguages.isEmpty {
            validateOrResetLanguages()
        }
    }

    private func validateOrResetLanguages() {
        // Pin to the exact Language object from supportedLanguages so the Picker binding
        // matches its tag. Try exact minimalIdentifier first (preserves pt-BR vs pt-PT),
        // then fall back to language-code match (e.g. "es" → "es-419").
        if let match = resolveLanguage(sourceLanguage, in: supportedLanguages) {
            sourceLanguage = match
        } else {
            sourceLanguage = Locale.current.language
            defaults.removeObject(forKey: Self.sourceKey)
        }
        if let match = resolveLanguage(targetLanguage, in: supportedLanguages) {
            targetLanguage = match
        } else {
            targetLanguage = supportedLanguages.first {
                $0.languageCode?.identifier == "en"
            } ?? Locale.Language(identifier: "en")
            defaults.removeObject(forKey: Self.targetKey)
        }
    }

    /// Returns the best match for `language` in `candidates`.
    /// Prefers exact `minimalIdentifier` match; falls back to language-code match.
    private func resolveLanguage(
        _ language: Locale.Language,
        in candidates: [Locale.Language]
    ) -> Locale.Language? {
        candidates.first { $0.minimalIdentifier == language.minimalIdentifier }
            ?? candidates.first { $0.languageCode?.identifier == language.languageCode?.identifier }
    }
}

// MARK: - LanguagePairStatus init from Apple enum

private extension LanguagePairStatus {
    init(from status: LanguageAvailability.Status) {
        switch status {
        case .installed:   self = .installed
        case .supported:   self = .supported
        case .unsupported: self = .unsupported
        @unknown default:  self = .unsupported
        }
    }
}
