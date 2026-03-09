@_exported import Testing
import Foundation
@testable import TranslateCall

// MARK: - LanguagePairStatus

@MainActor
struct LanguagePairStatusTests {

    @Test func statusEquality() {
        #expect(LanguagePairStatus.installed == .installed)
        #expect(LanguagePairStatus.supported == .supported)
        #expect(LanguagePairStatus.unsupported != .installed)
        #expect(LanguagePairStatus.unknown != .supported)
    }
}

// MARK: - LanguagePairManager

@Suite(.serialized) @MainActor
struct LanguagePairManagerTests {

    private static let sourceKey = "tlk.source.language"
    private static let targetKey = "tlk.target.language"

    private func clearDefaults() {
        UserDefaults.standard.removeObject(forKey: Self.sourceKey)
        UserDefaults.standard.removeObject(forKey: Self.targetKey)
    }

    /// Wait for the init Task (loadSupportedLanguages + checkAvailability) to settle.
    private func makeManager() async -> LanguagePairManager {
        let manager = LanguagePairManager()
        // Give the background init Task time to complete so validateOrResetLanguages
        // doesn't race with the test's setSourceLanguage/setTargetLanguage calls.
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
        return manager
    }

    @Test func defaultLanguagePairWithoutPersistedValues() async {
        clearDefaults()
        let manager = await makeManager()
        #expect(manager.sourceLanguage.languageCode != nil)
        #expect(manager.sourceLanguage != manager.targetLanguage)
    }

    @Test func persistsSourceLanguageToUserDefaults() async {
        clearDefaults()
        let manager = await makeManager()
        // Use "es" — guaranteed to be in Apple's supported translation languages
        await manager.setSourceLanguage(Locale.Language(identifier: "es"))
        let persisted = UserDefaults.standard.string(forKey: Self.sourceKey)
        #expect(persisted == "es")
        clearDefaults()
    }

    @Test func persistsTargetLanguageToUserDefaults() async {
        clearDefaults()
        let manager = await makeManager()
        await manager.setTargetLanguage(Locale.Language(identifier: "de"))
        let persisted = UserDefaults.standard.string(forKey: Self.targetKey)
        #expect(persisted == "de")
        clearDefaults()
    }

    @Test func swapLanguagesExchangesValues() async {
        clearDefaults()
        let manager = await makeManager()
        await manager.setSourceLanguage(Locale.Language(identifier: "en"))
        await manager.setTargetLanguage(Locale.Language(identifier: "es"))

        let srcBefore = manager.sourceLanguage.minimalIdentifier
        let tgtBefore = manager.targetLanguage.minimalIdentifier
        await manager.swapLanguages()

        #expect(manager.sourceLanguage.minimalIdentifier == tgtBefore)
        #expect(manager.targetLanguage.minimalIdentifier == srcBefore)
        clearDefaults()
    }

    @Test func loadsPersistedLanguagesOnInit() {
        // Pre-set known values — don't use makeManager() here since we want to
        // test that init() reads UserDefaults before the async task can reset them.
        UserDefaults.standard.set("pt", forKey: Self.sourceKey)
        UserDefaults.standard.set("it", forKey: Self.targetKey)
        let manager = LanguagePairManager()
        // The synchronous init (before Task runs) should have loaded these
        #expect(manager.sourceLanguage.minimalIdentifier == "pt")
        #expect(manager.targetLanguage.minimalIdentifier == "it")
        clearDefaults()
    }

    @Test func displayNameNonEmptyForCommonLanguage() async {
        let manager = await makeManager()
        let name = manager.displayName(for: Locale.Language(identifier: "es"))
        #expect(!name.isEmpty)
    }

    @Test func checkAvailabilityChangesStatusFromUnknown() async {
        clearDefaults()
        let manager = LanguagePairManager()
        // Status starts unknown before init task completes
        // After explicit checkAvailability it should resolve
        await manager.checkAvailability()
        #expect(manager.pairStatus != .unknown)
        clearDefaults()
    }
}
