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

    /// Isolated UserDefaults for a single test — avoids polluting .standard.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }

    /// Fake language loader — avoids calling LanguageAvailability (slow, real network/disk).
    /// nonisolated(unsafe) is safe here: immutable let, only read from @MainActor tests.
    nonisolated(unsafe) private static let fakeLanguages: [Locale.Language] = [
        Locale.Language(identifier: "es-419"),
        Locale.Language(identifier: "en-US"),
        Locale.Language(identifier: "fr-FR"),
        Locale.Language(identifier: "pt-BR"),
        Locale.Language(identifier: "pt-PT"),
        Locale.Language(identifier: "de"),
    ]

    private func makeIsolatedManager(
        defaults: UserDefaults,
        languages: [Locale.Language] = fakeLanguages
    ) async -> LanguagePairManager {
        let manager = LanguagePairManager(
            defaults: defaults,
            languageLoader: { languages }
        )
        // languageLoader is synchronous so one yield is enough for init Task to complete.
        await Task.yield()
        await Task.yield()
        return manager
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

    // MARK: - B2 fix: language restoration with isolated defaults + languageLoader

    @Test func savedSourceLanguageRestoredExact() async {
        // "es-419" should restore to Locale.Language("es-419") not just any Spanish
        let defs = makeDefaults()
        defs.set("es-419", forKey: Self.sourceKey)
        let manager = await makeIsolatedManager(defaults: defs)
        #expect(manager.sourceLanguage.minimalIdentifier == Locale.Language(identifier: "es-419").minimalIdentifier)
    }

    @Test func savedTargetLanguageRestoredExact() async {
        let defs = makeDefaults()
        defs.set("en-US", forKey: Self.targetKey)
        let manager = await makeIsolatedManager(defaults: defs)
        #expect(manager.targetLanguage.minimalIdentifier == Locale.Language(identifier: "en-US").minimalIdentifier)
    }

    @Test func savedSourceLanguageRestoredByCodeFallback() async {
        // "es" (no region) falls back to code match → "es-419" (first Spanish in fake list)
        let defs = makeDefaults()
        defs.set("es", forKey: Self.sourceKey)
        let manager = await makeIsolatedManager(defaults: defs)
        #expect(manager.sourceLanguage.languageCode?.identifier == "es")
    }

    @Test func ptBRRestoredToPtBRNotPtPT() async {
        // Exact match must return pt-BR, not pt-PT — validates the fix for the variant bug
        let defs = makeDefaults()
        defs.set(Locale.Language(identifier: "pt-BR").minimalIdentifier, forKey: Self.sourceKey)
        let manager = await makeIsolatedManager(defaults: defs)
        #expect(manager.sourceLanguage.minimalIdentifier == Locale.Language(identifier: "pt-BR").minimalIdentifier)
    }

    @Test func ptPTRestoredToPtPTNotPtBR() async {
        let defs = makeDefaults()
        defs.set(Locale.Language(identifier: "pt-PT").minimalIdentifier, forKey: Self.sourceKey)
        let manager = await makeIsolatedManager(defaults: defs)
        #expect(manager.sourceLanguage.minimalIdentifier == Locale.Language(identifier: "pt-PT").minimalIdentifier)
    }

    @Test func unknownSavedLanguageFallsBackToDefault() async {
        let defs = makeDefaults()
        defs.set("xx", forKey: Self.sourceKey)  // "xx" not in fake language list
        let manager = await makeIsolatedManager(defaults: defs)
        // Falls back to Locale.current.language — just verify no crash and languageCode is set
        #expect(manager.sourceLanguage.languageCode != nil)
        // UserDefaults key should be cleared
        #expect(defs.string(forKey: Self.sourceKey) == nil)
    }

    @Test func noSavedLanguageUsesDefaultsAfterLoad() async {
        let defs = makeDefaults()  // no keys set
        let manager = await makeIsolatedManager(defaults: defs)
        // With our fake list there's no "es" entry, but "es-419" exists and is code-matched
        #expect(manager.sourceLanguage.languageCode != nil)
        #expect(manager.targetLanguage.languageCode != nil)
        #expect(manager.sourceLanguage != manager.targetLanguage)
    }

    @Test func setSourceLanguageUsesInjectedDefaults() async {
        let defs = makeDefaults()
        let manager = await makeIsolatedManager(defaults: defs)
        await manager.setSourceLanguage(Locale.Language(identifier: "fr-FR"))
        #expect(defs.string(forKey: Self.sourceKey) == Locale.Language(identifier: "fr-FR").minimalIdentifier)
    }
}
