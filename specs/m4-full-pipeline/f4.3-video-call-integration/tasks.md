# F4.3 – Video Call Integration: Tasks

**Milestone**: M4 – Full Pipeline Integration
**Feature**: F4.3 – Video Call Integration
**Status**: DRAFT – Pending Gate 3 Review
**Date**: 2026-03-10

---

## Task Summary

| ID | Title | Files | Depends |
|----|-------|-------|---------|
| T1 | `VideoCallApp` enum + app catalog | `Core/Setup/VideoCallApp.swift` | — |
| T2 | `SetupManager` — BlackHole check, app loading, persistence | `Core/Setup/SetupManager.swift` | T1 |
| T3 | `RouteTestService` — TTS test tone to BlackHole | `Core/Setup/RouteTestService.swift` | T2 |
| T4 | Wire `SetupManager` into `AppContainer` + `AudioViewModel` | `App/AppContainer.swift`, `Features/Main/AudioViewModel.swift` | T2 |
| T5 | `SetupWizardView` shell + progress bar + navigation footer | `Features/Setup/SetupWizardView.swift` | T2 |
| T6 | Step 1: `Step1_BlackHoleCheckView` | `Features/Setup/Step1_BlackHoleCheckView.swift` | T5 |
| T7 | Step 2: `Step2_VideoAppInstructionView` | `Features/Setup/Step2_VideoAppInstructionView.swift` | T1, T5 |
| T8 | Step 3: `Step3_CaptureAppSelectView` | `Features/Setup/Step3_CaptureAppSelectView.swift` | T2, T5 |
| T9 | Step 4: `Step4_RouteTestView` | `Features/Setup/Step4_RouteTestView.swift` | T3, T5 |
| T10 | `SetupBannerView` + `CaptureAppSelectorView` + `ContentView` integration | `Features/Setup/SetupBannerView.swift`, `Features/ContentView.swift` | T2, T4 |
| T11 | Unit tests: `SetupManagerTests` + `VideoCallAppTests` | `TranslateCallTests/SetupManagerTests.swift`, `TranslateCallTests/VideoCallAppTests.swift` | T1, T2 |
| T12 | Full suite run + ROADMAP update + commit | — | T1–T11 |

---

## T1 — `VideoCallApp` enum

**File**: `TranslateCall/Core/Setup/VideoCallApp.swift` (CREATE)

### Checklist

- [ ] Define `enum VideoCallApp: String, CaseIterable, Identifiable` with cases: `.zoom`, `.teams`, `.meet`, `.discord`, `.generic`
- [ ] `rawValue` = bundle identifier string (`"us.zoom.xos"`, `"com.microsoft.teams2"`, `"com.google.meet"`, `"com.discord"`, `""`)
- [ ] `var id: String { rawValue }`
- [ ] `var displayName: String` — human-readable name per case
- [ ] `var sfSymbol: String` — SF Symbol name per case (e.g., `"video"` for generic, `"bubble.left.and.bubble.right"` for chat apps)
- [ ] `var settingsPath: String` — brief path string (e.g., `"Settings → Audio → Microphone"`)
- [ ] `var microphoneSteps: [String]` — numbered instruction strings (3–5 steps per app)
  - Zoom: Open Zoom → Settings → Audio → select "BlackHole 2ch" as Microphone
  - Teams: Open Teams → Settings → Devices → select "BlackHole 2ch" as Microphone
  - Meet: In browser → click mic icon → Settings → select "BlackHole 2ch"
  - Discord: Open Discord → Settings → Voice & Video → select "BlackHole 2ch" as Input Device
  - Generic: Open your video call app → Audio/Microphone settings → select "BlackHole 2ch"
- [ ] `var estimatedMinutes: Int` — e.g., 2 for all apps
- [ ] `static func matching(bundleID: String, displayName: String) -> VideoCallApp`:
  - First try `rawValue` match on `bundleID` (non-empty)
  - Then try case-insensitive `displayName` contains match against known app names
  - Fall back to `.generic`
- [ ] Build passes

---

## T2 — `SetupManager`

**File**: `TranslateCall/Core/Setup/SetupManager.swift` (CREATE)

### Checklist

- [ ] `@MainActor final class SetupManager: ObservableObject`
- [ ] `@Published private(set) var isSetupCompleted: Bool` — init from `UserDefaults.standard.bool(forKey: "tlk.setupCompleted")`
- [ ] `@Published private(set) var isBlackHolePresent: Bool` — init: `AudioDevice.deviceID(forNameContaining: "BlackHole") != nil`
- [ ] `@Published private(set) var availableCaptureApps: [SCRunningApplication] = []`
- [ ] `@Published private(set) var isLoadingCaptureApps: Bool = false`
- [ ] `@Published private(set) var selectedCaptureApp: SCRunningApplication?`
- [ ] `@Published private(set) var detectedVideoCallApp: VideoCallApp = .generic`
- [ ] `func checkBlackHole()` — re-evaluates `isBlackHolePresent` synchronously
- [ ] `func loadCaptureApps() async`:
  - Set `isLoadingCaptureApps = true`, defer false
  - Call `SCShareableContent.current()` (async, may throw)
  - Filter `content.applications` using `VideoCallApp.matching()` for known apps
  - If no known apps found, use all apps (fallback)
  - Set `availableCaptureApps`, `detectedVideoCallApp`, and call `restoreSelectedApp(from:)`
  - On error: set `availableCaptureApps = []`
- [ ] `func selectCaptureApp(_ app: SCRunningApplication?)`:
  - Set `selectedCaptureApp`
  - Persist `app?.bundleIdentifier ?? ""` to `UserDefaults` key `"tlk.captureApp.bundleID"`
- [ ] `func completeSetup()` — sets `isSetupCompleted = true`, persists to UserDefaults
- [ ] `func resetSetup()` — sets `isSetupCompleted = false`, clears UserDefaults key
- [ ] `private func restoreSelectedApp(from apps: [SCRunningApplication])`:
  - Read `"tlk.captureApp.bundleID"` from UserDefaults
  - Find matching app in `apps` by `bundleIdentifier`
  - Set `selectedCaptureApp` if found
- [ ] `@preconcurrency import ScreenCaptureKit` for `SCShareableContent`
- [ ] Build passes

---

## T3 — `RouteTestService`

**File**: `TranslateCall/Core/Setup/RouteTestService.swift` (CREATE)

### Checklist

- [ ] `@MainActor final class RouteTestService: ObservableObject`
- [ ] `enum TestState: Equatable { case idle, playing, succeeded, failed(String) }` — `Equatable` with manual `==` for `.failed`
- [ ] `@Published private(set) var state: TestState = .idle`
- [ ] `private let testPhrase = "Testing audio routing. TranslateCall is ready."` (English only for route test — always en-US)
- [ ] `func run(blackHoleDeviceID: AudioDeviceID?) async`:
  - Guard: if `blackHoleDeviceID == nil` → set `state = .failed("BlackHole not detected")`, return
  - Guard: if `state == .playing` → return (idempotent)
  - `state = .playing`
  - Create `AVSpeechService(outputDeviceID: deviceID)` in do/catch; on throw → `state = .failed(error.localizedDescription)`, return
  - Call `await tts.speak(text: testPhrase, locale: Locale(identifier: "en-US"))`
  - Observe `tts.isSpeakingStream`: loop until `!speaking`
  - `await tts.deactivate()`
  - `state = .succeeded`
- [ ] `func reset()` — sets `state = .idle`
- [ ] Build passes

---

## T4 — Wire `SetupManager` into `AppContainer` + `AudioViewModel`

**Files**: `App/AppContainer.swift`, `Features/Main/AudioViewModel.swift`, `App/TranslateCallApp.swift` (MODIFY)

### Checklist

**AppContainer.swift**:
- [ ] Add `let setupManager: SetupManager` stored property
- [ ] In `init()`: create `SetupManager()` and assign to `setupManager`

**AudioViewModel.swift**:
- [ ] Add `let setupManager: SetupManager` stored property
- [ ] Update designated `init(coordinator:audioManager:languagePairManager:)` to add `setupManager: SetupManager` parameter
- [ ] Update `AppContainer` call to pass `setupManager`
- [ ] In `toggleCapture()` → `coordinator.start(...)` call:
  - Pass `captureApp: setupManager.selectedCaptureApp`
  - Pass `blackHoleDeviceID: setupManager.isBlackHolePresent ? AudioDevice.deviceID(forNameContaining: "BlackHole") : nil`
  - (Replaces the hardcoded `captureApp: nil` and `AudioDevice.deviceID(...)` call)
- [ ] Update convenience init to create a `SetupManager()` internally (for tests/previews)

**TranslateCallApp.swift**:
- [ ] Add `.environmentObject(container.setupManager)` to the window group

### Build checklist
- [ ] Build passes, existing tests pass

---

## T5 — `SetupWizardView` shell + progress + footer

**File**: `Features/Setup/SetupWizardView.swift` (CREATE)

### Checklist

- [ ] `struct SetupWizardView: View` with `@ObservedObject var setupManager: SetupManager` and `@Binding var isPresented: Bool`
- [ ] `enum SetupStep: Int, CaseIterable { case blackHoleCheck=1, videoAppInstructions=2, captureAppSelect=3, routeTest=4 }`
- [ ] `@State private var currentStep: SetupStep = .blackHoleCheck`
- [ ] `@StateObject private var routeTestService = RouteTestService()`
- [ ] Progress bar at top: `SetupProgressView(current: currentStep.rawValue, total: 4)` — simple HStack of filled/empty circles or segments
- [ ] Content area: `switch currentStep` → placeholder `Text("Step \(currentStep.rawValue)")` for now (filled in T6–T9)
- [ ] Navigation footer: `HStack` with:
  - "Back" button (disabled on step 1) → decrement step
  - Spacer
  - Step counter "Step X of 4"
  - Spacer
  - "Next" / "Complete" button → increment step or call `setupManager.completeSetup(); isPresented = false`
- [ ] `"Dismiss"` button in toolbar (`.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Dismiss") { isPresented = false } } }`)
- [ ] `.frame(width: 480, height: 380)`
- [ ] `.task { await setupManager.loadCaptureApps() }` on appear
- [ ] Preview with mock data
- [ ] Build passes

---

## T6 — Step 1: `Step1_BlackHoleCheckView`

**File**: `Features/Setup/Step1_BlackHoleCheckView.swift` (CREATE)

### Checklist

- [ ] Show title "BlackHole Virtual Audio" + subtitle
- [ ] If `setupManager.isBlackHolePresent`:
  - Large green checkmark `Image(systemName: "checkmark.circle.fill")` + "BlackHole 2ch detected"
- [ ] If `!setupManager.isBlackHolePresent`:
  - Warning icon + "BlackHole 2ch not found"
  - Explanation: "TranslateCall routes translated speech through BlackHole so your video call app hears it as a microphone input."
  - Code block showing `brew install blackhole-2ch` with a copy button
  - Link: "Download installer" → opens `https://existential.audio/blackhole/` via `NSWorkspace.shared.open(_:)`
  - "Refresh" button → `setupManager.checkBlackHole()`
- [ ] Note at bottom: "Tip: You can continue to step 2 even without BlackHole — incoming translation will be unavailable until it is installed."
- [ ] Preview showing both states
- [ ] Build passes

---

## T7 — Step 2: `Step2_VideoAppInstructionView`

**File**: `Features/Setup/Step2_VideoAppInstructionView.swift` (CREATE)

### Checklist

- [ ] Accepts `app: VideoCallApp` parameter
- [ ] Header: SF Symbol icon + app display name + "Configure Microphone"
- [ ] Numbered list of `app.microphoneSteps` using `List` or `VStack` with `ForEach(steps.indices)`
  - Each row: `Text("\(index + 1). \(step)")`
- [ ] Estimated time footer: `"Estimated time: \(app.estimatedMinutes) minutes"`
- [ ] If `app == .generic`: show app picker `Picker("App", ...)` at top with `VideoCallApp.allCases.filter { $0 != .generic }` + "Other"
- [ ] Preview for each known app
- [ ] Build passes

---

## T8 — Step 3: `Step3_CaptureAppSelectView`

**File**: `Features/Setup/Step3_CaptureAppSelectView.swift` (CREATE)

### Checklist

- [ ] Title: "Select Capture Source" + subtitle explaining what this does
- [ ] If `setupManager.isLoadingCaptureApps`: show `ProgressView()`
- [ ] If `setupManager.availableCaptureApps.isEmpty` (after loading, no SCKit permission):
  - Show "No apps found" + "Grant Screen Recording permission" button → opens System Settings
- [ ] Else: `List` or `VStack` of apps:
  - "None (outgoing only)" row at top — checkmark if `selectedCaptureApp == nil`
  - One row per app in `availableCaptureApps`: `Text(app.applicationName)` + checkmark if selected
  - Tap → `setupManager.selectCaptureApp(app)` (or nil for "None")
- [ ] "Refresh" button → `Task { await setupManager.loadCaptureApps() }`
- [ ] Build passes

---

## T9 — Step 4: `Step4_RouteTestView`

**File**: `Features/Setup/Step4_RouteTestView.swift` (CREATE)

### Checklist

- [ ] Accepts `setupManager: SetupManager` and `routeTestService: RouteTestService`
- [ ] Title: "Test Audio Routing" + subtitle
- [ ] "Play Test" button (disabled when `routeTestService.state == .playing`):
  - Calls `Task { await routeTestService.run(blackHoleDeviceID: AudioDevice.deviceID(forNameContaining: "BlackHole")) }`
- [ ] States:
  - `.idle`: show instruction text + "Play Test" button
  - `.playing`: show pulsing circle animation + "Playing test tone…"
  - `.succeeded`: show `Image(systemName: "checkmark.circle.fill")` green + "Audio sent to BlackHole 2ch"
    + secondary text: "If you saw audio activity in your video call app, setup is complete!"
    + "Run Again" link → `routeTestService.reset()`
  - `.failed(let msg)`: show warning icon + error message + "Retry" button
- [ ] If BlackHole absent: show skip message without "Play Test" button
- [ ] Build passes

---

## T10 — Main window integration: `SetupBannerView` + `CaptureAppSelectorView` + `ContentView`

**Files**: `Features/Setup/SetupBannerView.swift` (CREATE), `Features/ContentView.swift` (MODIFY)

### Checklist

**SetupBannerView.swift**:
- [ ] `struct SetupBannerView: View` with `onSetupTap: () -> Void` closure
- [ ] Yellow/orange `HStack`: warning icon + "BlackHole not detected" + Spacer + "Setup…" Button → calls `onSetupTap()`
- [ ] `.padding(8)`, `.background(Color.yellow.opacity(0.15))`, `.cornerRadius(8)`
- [ ] Preview
- [ ] Build passes

**ContentView.swift**:
- [ ] Add `@EnvironmentObject private var setupManager: SetupManager`
- [ ] Add `@State private var showSetupWizard: Bool = false`
- [ ] Add `onAppear` / `onChange(of: scenePhase)` to call `setupManager.checkBlackHole()` on window focus
- [ ] Insert `SetupBannerView` row (conditional on `!setupManager.isBlackHolePresent`) between LanguagePairView and StatusBadgeView
- [ ] Insert `CaptureAppSelectorRow` inline (compact, 1 row) above `CaptureButtonView`:
  ```swift
  HStack {
      Text("Capture:").foregroundStyle(.secondary).font(.caption)
      Picker("", selection: captureBinding) {
          Text("None").tag(Optional<SCRunningApplication>.none)
          ForEach(setupManager.availableCaptureApps, id: \.processID) { app in
              Text(app.applicationName).tag(Optional(app))
          }
      }
      .labelsHidden()
      .frame(maxWidth: 160)
  }
  ```
  Where `captureBinding` is a `Binding<SCRunningApplication?>` that calls `setupManager.selectCaptureApp()` on change.
- [ ] "Setup…" text button in HStack with StatusBadge → `showSetupWizard = true`
- [ ] `.sheet(isPresented: $showSetupWizard) { SetupWizardView(setupManager: setupManager, isPresented: $showSetupWizard) }`
- [ ] Auto-show wizard on appear if `!setupManager.isSetupCompleted`:
  ```swift
  .onAppear { if !setupManager.isSetupCompleted { showSetupWizard = true } }
  ```
- [ ] Height: 560 (from 520)
- [ ] Build passes, existing tests pass

---

## T11 — Unit tests

**Files**: `TranslateCallTests/SetupManagerTests.swift`, `TranslateCallTests/VideoCallAppTests.swift` (CREATE)

### `VideoCallAppTests.swift` checklist
- [ ] `@Suite("VideoCallApp") @MainActor`
- [ ] `zoomMatchesByBundleID` — `VideoCallApp.matching(bundleID: "us.zoom.xos", displayName: "Zoom") == .zoom`
- [ ] `teamsMatchesByBundleID` — `VideoCallApp.matching(bundleID: "com.microsoft.teams2", displayName: "Teams") == .teams`
- [ ] `meetMatchesByDisplayName` — `VideoCallApp.matching(bundleID: "", displayName: "Meet") == .meet` (no bundle ID for web apps)
- [ ] `unknownAppReturnsGeneric` — `VideoCallApp.matching(bundleID: "com.unknown", displayName: "SomeApp") == .generic`
- [ ] `allKnownAppsHaveSteps` — `VideoCallApp.allCases.filter { $0 != .generic }.allSatisfy { !$0.microphoneSteps.isEmpty }` == true
- [ ] `allKnownAppsHaveSFSymbol` — `VideoCallApp.allCases.allSatisfy { !$0.sfSymbol.isEmpty }` == true

### `SetupManagerTests.swift` checklist
- [ ] `@Suite("SetupManager", .serialized) @MainActor` — use isolated UserDefaults (pass a test-specific `UserDefaults(suiteName:)` via dependency injection or reset keys in setUp/tearDown)
- [ ] `initialStateReflectsUserDefaults_false` — clear key, init, assert `!isSetupCompleted`
- [ ] `initialStateReflectsUserDefaults_true` — set key, init, assert `isSetupCompleted`
- [ ] `completeSetupSetsFlag` — init, complete, assert `isSetupCompleted == true` and UserDefaults == true
- [ ] `resetSetupClearsFlag` — complete, reset, assert `isSetupCompleted == false`
- [ ] `selectCaptureAppNilPersistsEmpty` — select nil, assert UserDefaults key == ""
- [ ] `checkBlackHoleUpdateState` — just verifies it doesn't crash and state is Bool (hardware-agnostic)

> **Note on UserDefaults isolation**: To avoid UserDefaults pollution between tests, inject a `UserDefaults` instance into `SetupManager.init`. Production code uses `.standard`; tests pass a `UserDefaults(suiteName: "test-\(UUID())")` instance.
>
> This requires modifying `SetupManager` to accept `UserDefaults` in init — add parameter `defaults: UserDefaults = .standard`.

---

## T12 — Integration + commit

### Checklist

- [ ] Run full test suite: `xcodebuild test ... CODE_SIGN_IDENTITY="-"` → `** TEST SUCCEEDED **` (modulo pre-existing flaky tests)
- [ ] Manual smoke: launch app, verify:
  - Wizard appears on first run
  - BlackHole banner shown/hidden correctly
  - Capture app selector populated
  - Route test plays audio to BlackHole
- [ ] `git add` all changed files
- [ ] `git commit`: `"Implement F4.3 — Setup wizard, capture app selector, route test (M4 complete)"`
- [ ] Update `ROADMAP.md`: mark F4.3 + M4 as COMPLETED
- [ ] Update `memory/MEMORY.md`

---

## Implementation Notes

### `SCShareableContent` — async/await vs completion handler
Use the async/await API available in macOS 12.3+:
```swift
let content = try await SCShareableContent.current()
```
This is simpler than the completion-handler overloads. Requires `@preconcurrency import ScreenCaptureKit` (already in project).

### `SCRunningApplication.applicationName` vs `displayName`
`SCRunningApplication` has `applicationName: String` (the property name in the current SDK) NOT `displayName`. Verify with Cupertino MCP before writing code.

### Pulsing animation for route test
Use a `@State var isPulsing: Bool` with `Circle().scaleEffect(isPulsing ? 1.4 : 1.0).animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: isPulsing)`.

### `SCShareableContent.current()` — availability
`SCShareableContent.current()` async is available macOS 13+. Since the deployment target is 15.0, this is fine.

### Window height
Change `ContentView` frame height from 520 → 560 to accommodate the new banner + selector rows (which are conditional — shown only when relevant).

---

*End of F4.3 Tasks — Gate 3 Review Pending*
