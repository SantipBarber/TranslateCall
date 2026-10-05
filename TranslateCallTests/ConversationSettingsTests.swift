import Foundation
import Testing
@testable import TranslateCall

/// A throwaway `UserDefaults` suite, removed by `clear()`.
private struct TestDefaults {
    let name = "ConversationSettingsTests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: name) ?? .standard }
    func clear() { UserDefaults().removePersistentDomain(forName: name) }
}

@Suite("ConversationSettings") @MainActor
struct ConversationSettingsTests {

    @Test("defaults: headphones and a 0.6 s pause (D-2, D-6)")
    func defaults() {
        let store = TestDefaults()
        defer { store.clear() }
        let settings = ConversationSettings(defaults: store.defaults)
        #expect(settings.listeningMode == .headphones)
        #expect(settings.pauseSeconds == 0.6)
        #expect(settings.vadConfiguration.minSilenceDuration == 0.6)
    }

    @Test("both settings survive a relaunch (REQ-H-01, REQ-V-05)")
    func persistence() {
        let store = TestDefaults()
        defer { store.clear() }
        let first = ConversationSettings(defaults: store.defaults)
        first.listeningMode = .speakers
        first.pauseSeconds = 0.9

        let second = ConversationSettings(defaults: store.defaults)
        #expect(second.listeningMode == .speakers)
        #expect(abs(second.pauseSeconds - 0.9) < 1e-9)
        #expect(abs(second.vadConfiguration.minSilenceDuration - 0.9) < 1e-9)
    }

    @Test("the pause is clamped to 0.4–1.2 s and rounded to 0.1 s")
    func pauseClamped() {
        let store = TestDefaults()
        defer { store.clear() }
        let settings = ConversationSettings(defaults: store.defaults)
        settings.pauseSeconds = 2
        #expect(settings.pauseSeconds == 1.2)
        settings.pauseSeconds = 0.05
        #expect(settings.pauseSeconds == 0.4)
        settings.pauseSeconds = 0.66
        #expect(abs(settings.pauseSeconds - 0.7) < 1e-9)
        settings.pauseSeconds = .nan
        #expect(settings.pauseSeconds == 0.6)
    }

    @Test("corrupt stored values fall back to the defaults")
    func corruptStoredValues() {
        let store = TestDefaults()
        defer { store.clear() }
        store.defaults.set("loud", forKey: ConversationSettings.listeningModeKey)
        store.defaults.set(9.0, forKey: ConversationSettings.pauseSecondsKey)
        let settings = ConversationSettings(defaults: store.defaults)
        #expect(settings.listeningMode == .headphones)
        #expect(settings.pauseSeconds == 1.2)
    }
}
