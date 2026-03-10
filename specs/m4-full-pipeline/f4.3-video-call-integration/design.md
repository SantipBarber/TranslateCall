# F4.3 – Video Call Integration: Design

**Milestone**: M4 – Full Pipeline Integration
**Feature**: F4.3 – Video Call Integration
**Status**: DRAFT – Pending Gate 2 Review
**Date**: 2026-03-10

---

## 1. Architecture Overview

```
AppContainer
  └─ SetupManager (@MainActor ObservableObject)
       ├─ isBlackHolePresent: Bool
       ├─ selectedCaptureApp: SCRunningApplication?
       ├─ isSetupCompleted: Bool
       ├─ func checkBlackHole()
       ├─ func loadCaptureApps() async
       └─ func runRouteTest() async

AudioViewModel
  ├─ setupManager: SetupManager   ← new dep (or observed separately)
  └─ toggleCapture() → coordinator.start(captureApp: setupManager.selectedCaptureApp, ...)

ContentView
  ├─ SetupBannerView               ← new: "BlackHole not detected" warning
  ├─ CaptureAppSelectorView        ← new: compact app picker row
  ├─ StatusBadgeView               ← existing, unchanged
  └─ "Setup…" button               ← new: re-opens wizard

SetupWizardView (sheet)
  ├─ Step1_BlackHoleCheckView
  ├─ Step2_VideoAppInstructionView
  ├─ Step3_CaptureAppSelectView
  └─ Step4_RouteTestView
```

---

## 2. New Types

### 2.1 `VideoCallApp` — Known App Catalog

```swift
// Core/Setup/VideoCallApp.swift

enum VideoCallApp: String, CaseIterable, Identifiable {
    case zoom     = "us.zoom.xos"
    case teams    = "com.microsoft.teams2"
    case meet     = "com.google.meet"       // browser-based — matched by displayName
    case discord  = "com.discord"
    case generic  = ""                      // fallback

    var id: String { rawValue }

    var displayName: String { ... }
    var settingsPath: String { ... }   // e.g., "Settings → Audio → Microphone"
    var microphoneSteps: [String] { ... }   // numbered instruction strings
    var sfSymbol: String { ... }

    /// Returns the app for a given bundle identifier or display name.
    static func matching(bundleID: String, displayName: String) -> VideoCallApp { ... }
}
```

`VideoCallApp.generic` is used when no known app matches.

---

### 2.2 `SetupManager`

```swift
// Core/Setup/SetupManager.swift

@MainActor
final class SetupManager: ObservableObject {

    // MARK: - Persisted state (UserDefaults)

    @Published private(set) var isSetupCompleted: Bool
    @Published private(set) var selectedCaptureApp: SCRunningApplication?

    // MARK: - Runtime state

    @Published private(set) var isBlackHolePresent: Bool = false
    @Published private(set) var availableCaptureApps: [SCRunningApplication] = []
    @Published private(set) var isLoadingCaptureApps: Bool = false
    @Published private(set) var detectedVideoCallApp: VideoCallApp = .generic

    // MARK: - Keys
    private static let setupCompletedKey = "tlk.setupCompleted"
    private static let captureAppBundleIDKey = "tlk.captureApp.bundleID"

    // MARK: - Init
    init() {
        isSetupCompleted = UserDefaults.standard.bool(forKey: Self.setupCompletedKey)
        isBlackHolePresent = AudioDevice.deviceID(forNameContaining: "BlackHole") != nil
        // selectedCaptureApp restored after loadCaptureApps() — bundle ID is persisted
    }

    // MARK: - Actions

    /// Re-checks BlackHole device presence (called on window focus).
    func checkBlackHole() {
        isBlackHolePresent = AudioDevice.deviceID(forNameContaining: "BlackHole") != nil
    }

    /// Fetches available running apps via SCShareableContent.
    /// Filters to known video call apps; falls back to all apps with audio.
    func loadCaptureApps() async {
        isLoadingCaptureApps = true
        defer { isLoadingCaptureApps = false }
        do {
            let content = try await SCShareableContent.current()
            let all = content.applications
            let known = all.filter { app in
                VideoCallApp.matching(
                    bundleID: app.bundleIdentifier ?? "",
                    displayName: app.applicationName
                ) != .generic
            }
            availableCaptureApps = known.isEmpty ? all : known
            restoreSelectedApp(from: all)
            detectedVideoCallApp = known.first.map {
                VideoCallApp.matching(bundleID: $0.bundleIdentifier ?? "", displayName: $0.applicationName)
            } ?? .generic
        } catch {
            availableCaptureApps = []
        }
    }

    /// Sets and persists the selected capture app.
    func selectCaptureApp(_ app: SCRunningApplication?) {
        selectedCaptureApp = app
        UserDefaults.standard.set(app?.bundleIdentifier ?? "", forKey: Self.captureAppBundleIDKey)
    }

    /// Marks setup as complete.
    func completeSetup() {
        isSetupCompleted = true
        UserDefaults.standard.set(true, forKey: Self.setupCompletedKey)
    }

    /// Resets setup state (for re-running wizard).
    func resetSetup() {
        isSetupCompleted = false
        UserDefaults.standard.set(false, forKey: Self.setupCompletedKey)
    }

    // MARK: - Private

    private func restoreSelectedApp(from apps: [SCRunningApplication]) {
        let savedBundleID = UserDefaults.standard.string(forKey: Self.captureAppBundleIDKey) ?? ""
        guard !savedBundleID.isEmpty else { return }
        selectedCaptureApp = apps.first { $0.bundleIdentifier == savedBundleID }
    }
}
```

---

### 2.3 `SetupWizardView` — 4-step sheet

```swift
// Features/Setup/SetupWizardView.swift

struct SetupWizardView: View {
    @ObservedObject var setupManager: SetupManager
    @State private var currentStep: SetupStep = .blackHoleCheck
    @Binding var isPresented: Bool

    enum SetupStep: Int, CaseIterable {
        case blackHoleCheck = 1
        case videoAppInstructions = 2
        case captureAppSelect = 3
        case routeTest = 4
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            SetupProgressView(currentStep: currentStep.rawValue, totalSteps: 4)

            // Step content
            switch currentStep {
            case .blackHoleCheck:
                Step1_BlackHoleCheckView(setupManager: setupManager)
            case .videoAppInstructions:
                Step2_VideoAppInstructionView(app: setupManager.detectedVideoCallApp)
            case .captureAppSelect:
                Step3_CaptureAppSelectView(setupManager: setupManager)
            case .routeTest:
                Step4_RouteTestView(setupManager: setupManager, isPresented: $isPresented)
            }

            // Navigation footer
            SetupNavigationFooter(
                currentStep: $currentStep,
                canAdvance: canAdvance,
                onComplete: { setupManager.completeSetup(); isPresented = false }
            )
        }
        .frame(width: 480, height: 380)
        .task { await setupManager.loadCaptureApps() }
    }

    private var canAdvance: Bool {
        switch currentStep {
        case .blackHoleCheck: return true  // can proceed even without BlackHole (degraded mode)
        case .videoAppInstructions: return true
        case .captureAppSelect: return true
        case .routeTest: return true
        }
    }
}
```

---

### 2.4 Step Views

**Step1_BlackHoleCheckView**:
```swift
// Shows:
// - ✅ "BlackHole 2ch detected" (green) OR
// - ⚠️ "BlackHole 2ch not found" + install command
//   `brew install blackhole-2ch` in a copyable code block
// - "Refresh" button → calls setupManager.checkBlackHole()
// - "Skip" link → advances to next step (incoming pipeline will be disabled)
```

**Step2_VideoAppInstructionView**:
```swift
// Shows per-app instruction card from VideoCallApp enum.
// If no app detected → generic instructions with app selector at top.
// Card shows: app icon + name, numbered steps, estimated time.
```

**Step3_CaptureAppSelectView**:
```swift
// List or Picker of availableCaptureApps
// + "None (outgoing only)" option at top
// Selected app highlighted with checkmark
// If isLoadingCaptureApps → ProgressView
// If empty → "No supported apps running. Launch Zoom, Teams, or Meet first."
// "Refresh" button → await setupManager.loadCaptureApps()
```

**Step4_RouteTestView**:
```swift
// "Test Routing" button → calls AudioViewModel.runRouteTest()
// Plays: "Testing audio routing. TranslateCall is ready." via TTS to BlackHole
// During playback: animated waveform placeholder (Circle pulse animation)
// After playback: ✅ "Audio sent to BlackHole 2ch"
// CTA: "Did you hear audio in your video call app? → [Yes, complete setup] [Run again]"
// If BlackHole absent: "BlackHole not detected — skipping audio test" with warning
```

---

### 2.5 `RouteTestService`

```swift
// Core/Setup/RouteTestService.swift

@MainActor
final class RouteTestService {
    enum State { case idle, playing, succeeded, failed(String) }
    @Published private(set) var state: State = .idle

    private let testPhrase = "Testing audio routing. TranslateCall is ready."

    func run(blackHoleDeviceID: AudioDeviceID?) async {
        guard let deviceID = blackHoleDeviceID else {
            state = .failed("BlackHole not detected")
            return
        }
        state = .playing
        do {
            let tts = try AVSpeechService(outputDeviceID: deviceID)
            let locale = Locale(identifier: "en-US")
            await tts.speak(text: testPhrase, locale: locale)
            // Wait for TTS to complete (observe isSpeakingStream)
            for await speaking in tts.isSpeakingStream {
                if !speaking { break }
            }
            await tts.deactivate()
            state = .succeeded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
```

---

### 2.6 Changes to Existing Types

**`AppContainer`**:
```swift
// Add:
let setupManager: SetupManager

// In init():
let setupManager = SetupManager()
self.setupManager = setupManager
```

**`AudioViewModel`**:
```swift
// Add:
let setupManager: SetupManager

// In toggleCapture():
await coordinator.start(
    captureApp: setupManager.selectedCaptureApp,
    blackHoleDeviceID: setupManager.isBlackHolePresent
        ? AudioDevice.deviceID(forNameContaining: "BlackHole")
        : nil
)
```

**`TranslateCallApp`**:
```swift
// Inject setupManager as environment object:
.environmentObject(container.setupManager)
```

**`ContentView`**:
```swift
// Add: @EnvironmentObject var setupManager: SetupManager
// Add: SetupBannerView (shown when !setupManager.isBlackHolePresent)
// Add: CaptureAppSelectorView (compact picker row)
// Add: "Setup…" button
// Add: .sheet(isPresented: $showWizard) { SetupWizardView(...) }
// On appear: setupManager.checkBlackHole()
```

---

## 3. File Map

| File | Change | Notes |
|------|--------|-------|
| `Core/Setup/VideoCallApp.swift` | **CREATE** | App catalog enum with instructions |
| `Core/Setup/SetupManager.swift` | **CREATE** | BlackHole check, app loading, persistence |
| `Core/Setup/RouteTestService.swift` | **CREATE** | Route test playback via AVSpeechService |
| `Features/Setup/SetupWizardView.swift` | **CREATE** | 4-step wizard shell + progress bar |
| `Features/Setup/Step1_BlackHoleCheckView.swift` | **CREATE** | BlackHole detection + install guide |
| `Features/Setup/Step2_VideoAppInstructionView.swift` | **CREATE** | Per-app instruction card |
| `Features/Setup/Step3_CaptureAppSelectView.swift` | **CREATE** | Running app picker |
| `Features/Setup/Step4_RouteTestView.swift` | **CREATE** | Route test UI |
| `Features/Setup/SetupBannerView.swift` | **CREATE** | Warning banner for main window |
| `TranslateCall/App/AppContainer.swift` | **MODIFY** | Add SetupManager |
| `TranslateCall/App/TranslateCallApp.swift` | **MODIFY** | Inject setupManager env object |
| `TranslateCall/Features/Main/AudioViewModel.swift` | **MODIFY** | Use setupManager in toggleCapture |
| `TranslateCall/Features/ContentView.swift` | **MODIFY** | Add banner, selector, wizard trigger |
| `TranslateCallTests/SetupManagerTests.swift` | **CREATE** | Unit tests |

---

## 4. `ContentView` Layout (Updated)

```
┌─────────────────────────────────────────┐
│  [Mic: Built-in ▼]  [Output: Speakers ▼]│  ← DeviceSectionView (unchanged)
│─────────────────────────────────────────│
│  ES ↔ EN  [Swap]                        │  ← LanguagePairView (unchanged)
│─────────────────────────────────────────│
│  ⚠ BlackHole not detected  [Setup…]     │  ← SetupBannerView (NEW, conditional)
│  Capture: [Zoom ▼]           [Setup…]   │  ← CaptureAppSelectorView (NEW)
│─────────────────────────────────────────│
│  🟢 Listening  🎧                       │  ← StatusBadgeView (unchanged)
│  ─────────────────────────────────      │
│  [level meter]                          │
│─────────────────────────────────────────│
│  ↑ Outgoing   ↓ Incoming               │  ← TranscriptionView (unchanged)
│  ...                                    │
│─────────────────────────────────────────│
│              [▶ Start]                  │  ← CaptureButtonView (unchanged)
└─────────────────────────────────────────┘

Window height: 560 (up from 520 for new rows)
```

---

## 5. UserDefaults Keys

| Key | Type | Purpose |
|-----|------|---------|
| `tlk.setupCompleted` | Bool | Wizard has been fully completed |
| `tlk.captureApp.bundleID` | String | Bundle ID of selected capture app |

(Existing keys: `tlk.source.language`, `tlk.target.language` from F3.2)

---

## 6. Test Strategy

**`SetupManagerTests.swift`** (`@Suite(.serialized) @MainActor`):

1. `isBlackHolePresentTrueWhenDeviceExists` — hard to unit test (hardware dep) → test false path with mock
2. `loadCaptureAppsFiltersKnownApps` — can't mock `SCShareableContent` (final class) → test `VideoCallApp.matching()` logic instead
3. `selectCaptureAppPersistsBundleID` — set app, read UserDefaults
4. `completeSetupSetsUserDefaults` — verify key written
5. `resetSetupClearsUserDefaults` — verify key cleared
6. `captureAppRestoredOnInit` — write bundleID to UserDefaults, re-init, verify app reloaded

**`VideoCallAppTests.swift`**:
1. `zoomMatchesByBundleID` — `VideoCallApp.matching(bundleID: "us.zoom.xos", ...)` == .zoom
2. `teamsMatchesByBundleID`
3. `unknownAppReturnsGeneric`
4. `instructionStepsNotEmpty` — all known apps have > 0 steps
5. `sfSymbolNotEmpty` — all known apps have valid SF symbol name

---

## 7. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| `SCShareableContent.current()` slow on first call (permission dialog) | Medium | UX | Show ProgressView; load async in background |
| `SCRunningApplication.bundleIdentifier` nil for some apps | Medium | Low | Fall back to `applicationName` matching |
| Route test plays audio at full volume unexpectedly | Low | UX | Use `SynthesisConfiguration` with moderate volume; document behavior |
| `AVSpeechService` for route test conflicts with active session | Low | Medium | Route test disabled if session is active; guard in `RouteTestService` |

---

*End of F4.3 Design — Gate 2 Review Pending*
