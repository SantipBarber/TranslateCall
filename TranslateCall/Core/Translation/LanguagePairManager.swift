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

    private let defaults = UserDefaults.standard
    private static let sourceKey = "tlk.source.language"
    private static let targetKey = "tlk.target.language"

    init() {
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
        let availability = LanguageAvailability()
        let langs = await availability.supportedLanguages
        supportedLanguages = langs.sorted { displayName(for: $0) < displayName(for: $1) }
        if !supportedLanguages.isEmpty {
            validateOrResetLanguages()
        }
    }

    private func validateOrResetLanguages() {
        let ids = Set(supportedLanguages.map { $0.minimalIdentifier })
        if !ids.contains(sourceLanguage.minimalIdentifier) {
            sourceLanguage = Locale.current.language
            defaults.removeObject(forKey: Self.sourceKey)
        }
        if !ids.contains(targetLanguage.minimalIdentifier) {
            targetLanguage = Locale.Language(identifier: "en")
            defaults.removeObject(forKey: Self.targetKey)
        }
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
