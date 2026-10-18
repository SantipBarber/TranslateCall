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

        #expect(opener.open(tab: .advanced))
        #expect(defaults.string(forKey: SettingsOpener.tabKey) == "advanced")
        #expect(activations == 1 && opens == 1)
    }

    @Test("three tabs; the feature-1 legacy value opens Advanced (REQ-ST-51)")
    func tabs() {
        #expect(SettingsTab.allCases == [.general, .voices, .advanced])
        #expect(SettingsTab(rawValue: "advancedLegacy") == .advanced)
        #expect(SettingsTab(rawValue: "nope") == nil)
    }

    @Test("before the setup window handed openSettings over, it reports failure but keeps the tab")
    func noHandlerYet() {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let opener = SettingsOpener(defaults: defaults, activate: {})
        #expect(!opener.open(tab: .general))
        #expect(defaults.string(forKey: SettingsOpener.tabKey) == "general")
    }
}
