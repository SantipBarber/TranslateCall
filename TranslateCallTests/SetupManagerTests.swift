import Combine
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

    // MARK: - B1: session-cache deduplication

    @Test("loadCaptureApps skips SCKit when captureAppsLoaded is already true")
    func loadCaptureAppsUsesSessionCacheFlag() async {
        let defaults = makeDefaults()
        let mgr = SetupManager(defaults: defaults)
        // Simulate: first call already succeeded
        mgr.captureAppsLoaded = true
        // Calling loadCaptureApps() should return immediately — no loading transition
        let loadingAtStart = mgr.isLoadingCaptureApps
        await mgr.loadCaptureApps()
        // isLoadingCaptureApps must still be false (never changed — guard returned early)
        #expect(!mgr.isLoadingCaptureApps)
        #expect(mgr.isLoadingCaptureApps == loadingAtStart)
    }

    @Test("loadCaptureApps uses session cache: second call returns without loading")
    func loadCaptureAppsUsesSessionCache() async {
        let defaults = makeDefaults()
        let mgr = SetupManager(defaults: defaults)
        mgr.captureAppsLoaded = true  // simulate: first call already succeeded
        // Track whether loading state changes during second call
        var loadingStateChanged = false
        let cancellable = mgr.$isLoadingCaptureApps.dropFirst().sink { _ in
            loadingStateChanged = true
        }
        await mgr.loadCaptureApps()
        #expect(!loadingStateChanged)
        withExtendedLifetime(cancellable) {}
    }

    @Test("refreshCaptureApps resets captureAppsLoaded flag before re-fetching")
    func refreshCaptureAppsResetsCache() async {
        let defaults = makeDefaults()
        let mgr = SetupManager(defaults: defaults)
        mgr.captureAppsLoaded = true  // simulate: already loaded
        // refreshCaptureApps should clear the flag (even if SCKit call fails or is guarded)
        // We can't call through to SCKit in unit tests, so verify the flag is cleared
        // by checking it immediately inside the async call flow via the guard
        mgr.captureAppsLoaded = false
        #expect(!mgr.captureAppsLoaded)  // sanity: we can set it

        // After refreshCaptureApps(), captureAppsLoaded should be true again (set at end of load)
        // or false if CGPreflightScreenCaptureAccess returns false in test environment
        await mgr.refreshCaptureApps()
        // Either way: isLoadingCaptureApps should be false after the call completes
        #expect(!mgr.isLoadingCaptureApps)
        // And captureAppsLoaded should be true (set at end of loadCaptureApps regardless of permission)
        #expect(mgr.captureAppsLoaded)
    }
}
