import Foundation
import Testing
@testable import TranslateCall

@Suite("SettingsOpener (M9 UI core REQ-UI-70)") @MainActor
struct SettingsOpenerTests {

    @Test("open(tab:) stores the tab, activates the app and calls SwiftUI's openSettings")
    func opensOnTab() {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        var activations = 0
        var opens = 0
        let opener = SettingsOpener(defaults: defaults, activate: { activations += 1 })
        opener.openSettings = { opens += 1 }

        #expect(opener.open(tab: .advancedLegacy))
        #expect(defaults.string(forKey: SettingsOpener.tabKey) == "advancedLegacy")
        #expect(activations == 1 && opens == 1)
    }

    @Test("before the setup window handed openSettings over, it reports failure but keeps the tab")
    func noHandlerYet() {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let opener = SettingsOpener(defaults: defaults, activate: {})
        #expect(!opener.open(tab: .general))
        #expect(defaults.string(forKey: SettingsOpener.tabKey) == "general")
    }
}
