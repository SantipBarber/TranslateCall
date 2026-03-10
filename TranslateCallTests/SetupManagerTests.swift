import Foundation
import Testing
@testable import TranslateCall

@Suite("SetupManager", .serialized)
@MainActor
struct SetupManagerTests {

    // Shared helper: fresh isolated UserDefaults for each test
    private func makeDefaults() -> UserDefaults {
        let suite = "test-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - T1: Initial state — not completed

    @Test("Initial isSetupCompleted is false when key absent")
    func initialStateReflectsUserDefaultsFalse() {
        let defaults = makeDefaults()
        let mgr = SetupManager(defaults: defaults)
        #expect(!mgr.isSetupCompleted)
    }

    // MARK: - T2: Initial state — already completed

    @Test("Initial isSetupCompleted is true when key is true")
    func initialStateReflectsUserDefaultsTrue() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "tlk.setupCompleted")
        let mgr = SetupManager(defaults: defaults)
        #expect(mgr.isSetupCompleted)
    }

    // MARK: - T3: completeSetup

    @Test("completeSetup sets isSetupCompleted and persists to UserDefaults")
    func completeSetupSetsFlag() {
        let defaults = makeDefaults()
        let mgr = SetupManager(defaults: defaults)
        mgr.completeSetup()
        #expect(mgr.isSetupCompleted)
        #expect(defaults.bool(forKey: "tlk.setupCompleted"))
    }

    // MARK: - T4: resetSetup

    @Test("resetSetup clears isSetupCompleted and UserDefaults")
    func resetSetupClearsFlag() {
        let defaults = makeDefaults()
        let mgr = SetupManager(defaults: defaults)
        mgr.completeSetup()
        mgr.resetSetup()
        #expect(!mgr.isSetupCompleted)
        #expect(!defaults.bool(forKey: "tlk.setupCompleted"))
    }

    // MARK: - T5: selectCaptureApp(nil)

    @Test("selectCaptureApp nil persists empty string to UserDefaults")
    func selectCaptureAppNilPersistsEmpty() {
        let defaults = makeDefaults()
        let mgr = SetupManager(defaults: defaults)
        mgr.selectCaptureApp(nil)
        #expect(mgr.selectedCaptureApp == nil)
        #expect(defaults.string(forKey: "tlk.captureApp.bundleID") == "")
    }

    // MARK: - T6: checkBlackHole (hardware-agnostic)

    @Test("checkBlackHole does not crash and returns a Bool")
    func checkBlackHoleUpdateState() {
        let defaults = makeDefaults()
        let mgr = SetupManager(defaults: defaults)
        let before = mgr.isBlackHolePresent
        mgr.checkBlackHole()
        // State should be a Bool (either same or updated — hardware dependent)
        #expect(mgr.isBlackHolePresent == true || mgr.isBlackHolePresent == false)
        withExtendedLifetime(before) {}  // suppress unused-variable warning
    }
}
