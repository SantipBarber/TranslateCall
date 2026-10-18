import Foundation
import Synchronization
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

/// Counts calls in flight and remembers the highest count.
private final class InFlightGauge: Sendable {
    private let state = Mutex<(now: Int, peak: Int)>((0, 0))
    var peak: Int { state.withLock { $0.peak } }
    func enter() { state.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) } }
    func leave() { state.withLock { $0.now -= 1 } }
}

@Suite("General settings — UI-B9 (M9 UI settings REQ-ST-60)") @MainActor
struct GeneralSettingsBacklogTests {

    @Test("Open at login re-reads the system status on refresh")
    func openAtLoginRefresh() {
        var enabled = false
        let login = OpenAtLoginModel(isEnabled: { enabled }, register: {}, unregister: {})
        enabled = true
        #expect(!login.isEnabled)
        login.refresh()
        #expect(login.isEnabled)
    }

    @Test("the per-language checks run concurrently")
    func checksRunConcurrently() async {
        let gauge = InFlightGauge()
        let list = await DownloadedLanguages.list(
            source: Locale.Language(identifier: "es"),
            supported: ["de", "en", "fr", "it"].map(Locale.Language.init(identifier:)),
            displayName: { $0.minimalIdentifier },
            isInstalled: { _, _ in
                gauge.enter()
                try? await Task.sleep(for: .milliseconds(50))
                gauge.leave()
                return true
            })
        #expect(list == ["de", "en", "es", "fr", "it"])
        #expect(gauge.peak > 1)
    }
}
