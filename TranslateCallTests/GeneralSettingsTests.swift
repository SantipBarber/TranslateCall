import Foundation
import Testing
@testable import TranslateCall

struct GeneralSettingsTests {
    @Test func pauseLabel() {
        #expect(GeneralSettingsView.pauseValueLabel(0.6) == "0.6 s pause")
        #expect(GeneralSettingsView.pauseValueLabel(1.2) == "1.2 s pause")
    }

    @Test func downloadedLanguages() async {
        let names = ["es": "Español", "de": "Deutsch", "en": "English", "fr": "Français"]
        let list = await DownloadedLanguages.list(
            source: Locale.Language(identifier: "es"),
            supported: ["de", "en", "fr"].map(Locale.Language.init(identifier:)),
            displayName: { names[$0.minimalIdentifier] ?? $0.minimalIdentifier },
            isInstalled: { _, target in ["de", "en"].contains(target.minimalIdentifier) })
        #expect(list == ["Deutsch", "English", "Español"])
    }

    @Test func downloadedLanguagesSkipsSourceDuplicate() async {
        let es = Locale.Language(identifier: "es")
        let list = await DownloadedLanguages.list(
            source: es, supported: [es], displayName: { _ in "Español" }, isInstalled: { _, _ in true })
        #expect(list == ["Español"])
    }
}
