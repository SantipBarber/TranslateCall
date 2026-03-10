import Combine
import Foundation
@preconcurrency import ScreenCaptureKit

// MARK: - SetupManager

/// Manages first-launch setup state: BlackHole readiness, capture app selection, wizard completion.
///
/// All state is `@Published` and `@MainActor`-isolated. Persists key values in `UserDefaults`.
@MainActor
final class SetupManager: ObservableObject {

    // MARK: - UserDefaults keys

    private static let setupCompletedKey  = "tlk.setupCompleted"
    private static let captureAppBundleKey = "tlk.captureApp.bundleID"

    // MARK: - Persisted state

    @Published private(set) var isSetupCompleted: Bool
    @Published private(set) var selectedCaptureApp: SCRunningApplication?

    // MARK: - Runtime state

    @Published private(set) var isBlackHolePresent: Bool
    @Published private(set) var availableCaptureApps: [SCRunningApplication] = []
    @Published private(set) var isLoadingCaptureApps: Bool = false
    @Published private(set) var detectedVideoCallApp: VideoCallApp = .generic

    // MARK: - Private storage

    private let defaults: UserDefaults

    // MARK: - Init

    /// - Parameter defaults: UserDefaults instance. Pass a test-specific suite in unit tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isSetupCompleted = defaults.bool(forKey: Self.setupCompletedKey)
        isBlackHolePresent = AudioDevice.deviceID(forNameContaining: "BlackHole") != nil
    }

    // MARK: - BlackHole check

    /// Re-evaluates BlackHole presence synchronously (call on window focus).
    func checkBlackHole() {
        isBlackHolePresent = AudioDevice.deviceID(forNameContaining: "BlackHole") != nil
    }

    // MARK: - Capture app loading

    /// Fetches running applications via SCShareableContent.
    /// Only proceeds if Screen Recording permission is already granted — never triggers the dialog
    /// automatically. Call `requestScreenCapturePermission()` to prompt the user explicitly.
    func loadCaptureApps() async {
        guard CGPreflightScreenCaptureAccess() else {
            availableCaptureApps = []
            return
        }
        isLoadingCaptureApps = true
        defer { isLoadingCaptureApps = false }
        do {
            let content = try await SCShareableContent.current
            let all = content.applications
            let known = all.filter { app in
                VideoCallApp.matching(
                    bundleID: app.bundleIdentifier ?? "",
                    displayName: app.applicationName
                ) != .generic
            }
            availableCaptureApps = known.isEmpty ? all : known
            detectedVideoCallApp = known.first.map {
                VideoCallApp.matching(
                    bundleID: $0.bundleIdentifier ?? "",
                    displayName: $0.applicationName
                )
            } ?? .generic
            restoreSelectedApp(from: all)
        } catch {
            availableCaptureApps = []
        }
    }

    /// Requests Screen Recording permission (shows system dialog if not yet granted),
    /// then loads available capture apps.
    func requestScreenCapturePermission() async {
        CGRequestScreenCaptureAccess()
        // Allow time for the permission decision to propagate before checking
        try? await Task.sleep(for: .milliseconds(500))
        await loadCaptureApps()
    }

    // MARK: - Capture app selection

    /// Selects and persists the capture app (nil = "None / outgoing only").
    func selectCaptureApp(_ app: SCRunningApplication?) {
        selectedCaptureApp = app
        defaults.set(app?.bundleIdentifier ?? "", forKey: Self.captureAppBundleKey)
    }

    // MARK: - Wizard completion

    func completeSetup() {
        isSetupCompleted = true
        defaults.set(true, forKey: Self.setupCompletedKey)
    }

    func resetSetup() {
        isSetupCompleted = false
        defaults.set(false, forKey: Self.setupCompletedKey)
    }

    // MARK: - Private

    private func restoreSelectedApp(from apps: [SCRunningApplication]) {
        let saved = defaults.string(forKey: Self.captureAppBundleKey) ?? ""
        guard !saved.isEmpty else { return }
        selectedCaptureApp = apps.first { $0.bundleIdentifier == saved }
    }
}
