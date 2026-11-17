import Combine
import Foundation

// MARK: - SetupManager

/// Manages first-launch setup state: BlackHole readiness, call app selection, assistant completion.
///
/// All state is `@Published` and `@MainActor`-isolated. Persists key values in `UserDefaults`.
@MainActor
final class SetupManager: ObservableObject {

    // MARK: - UserDefaults keys

    private static let setupCompletedKey  = "tlk.setupCompleted"
    private static let captureAppBundleKey = "tlk.captureApp.bundleID"
    private static let stepKey = "tlk.setup.step"
    private static let callAppMicConfirmedKey = "tlk.setup.callAppMicConfirmed"

    // MARK: - Persisted state

    @Published private(set) var isSetupCompleted: Bool
    /// The persisted call app (`tlk.captureApp.bundleID`); nil = "None — translate only my voice".
    /// Set by both setters; works for an app that is not running (M9 UI core REQ-UI-80b).
    @Published private(set) var selectedCaptureBundleID: String?

    /// The assistant's current step, persisted so a relaunch for a permission resumes there
    /// (REQ-FR-03). Unknown or absent values read as `.permissions`.
    @Published var currentStep: SetupStep {
        didSet {
            // `.permissions` is the fallback for an absent key, so it is stored as "absent".
            if currentStep == .permissions {
                defaults.removeObject(forKey: Self.stepKey)
            } else {
                defaults.set(currentStep.rawValue, forKey: Self.stepKey)
            }
        }
    }

    /// "I've done it" was pressed on step 3; the step is trusted, not verified (REQ-FR-32, F-5).
    @Published private(set) var callAppMicConfirmed: Bool

    // MARK: - Runtime state

    @Published private(set) var isBlackHolePresent: Bool
    @Published private(set) var hasOtherBlackHole: Bool

    // MARK: - Private storage

    private let defaults: UserDefaults
    // MARK: - Init

    /// - Parameter defaults: UserDefaults instance. Pass a test-specific suite in unit tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isSetupCompleted = defaults.bool(forKey: Self.setupCompletedKey)
        let saved = defaults.string(forKey: Self.captureAppBundleKey) ?? ""
        selectedCaptureBundleID = saved.isEmpty ? nil : saved
        isBlackHolePresent = BlackHoleDevice.find() != nil
        hasOtherBlackHole = BlackHoleDevice.hasOtherBlackHole()
        currentStep = SetupStep(rawValue: defaults.integer(forKey: Self.stepKey)) ?? .permissions
        callAppMicConfirmed = defaults.bool(forKey: Self.callAppMicConfirmedKey)
    }

    // MARK: - Call app microphone step

    /// Marks step 3 as done and persists it (REQ-FR-32/33).
    func confirmCallAppMic() {
        callAppMicConfirmed = true
        defaults.set(true, forKey: Self.callAppMicConfirmedKey)
    }

    // MARK: - BlackHole check

    /// Re-evaluates BlackHole presence synchronously (call on window focus).
    func checkBlackHole() {
        isBlackHolePresent = BlackHoleDevice.find() != nil
        hasOtherBlackHole = BlackHoleDevice.hasOtherBlackHole()
    }

    // MARK: - Capture app selection

    /// Selects and persists the capture app by bundle ID, running or not (nil = "None").
    /// Persists before publishing, so observers of `selectedCaptureBundleID` read the new target.
    func selectCaptureApp(bundleID: String?) {
        let id = bundleID?.isEmpty == false ? bundleID : nil
        defaults.set(id ?? "", forKey: Self.captureAppBundleKey)
        selectedCaptureBundleID = id
    }

    /// True once the user (or the assistant) has picked a call app or "None" (the key exists).
    var hasCallAppChoice: Bool { defaults.object(forKey: Self.captureAppBundleKey) != nil }

    /// Incoming capture target from the persisted selection (F8.5.1 REQ-C-22). Independent of
    /// whether the app is running now: a missing app becomes `targetNotFound` + Retry at start.
    var captureTarget: CaptureTarget? {
        let bundleID = defaults.string(forKey: Self.captureAppBundleKey) ?? ""
        return bundleID.isEmpty ? nil : .app(bundleID: bundleID)
    }

    // MARK: - Wizard completion

    func completeSetup() {
        isSetupCompleted = true
        defaults.set(true, forKey: Self.setupCompletedKey)
        // REQ-FR-03: completing setup clears the stored step; the next run starts at step 1.
        currentStep = .permissions
    }

    func resetSetup() {
        isSetupCompleted = false
        defaults.set(false, forKey: Self.setupCompletedKey)
    }
}
