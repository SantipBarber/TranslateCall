# F1.3 - Basic UI Shell
## Implementation Tasks

**Feature**: F1.3
**Milestone**: M1 - Foundation
**Status**: COMPLETED — 2026-03-07
**Last Updated**: 2026-03-07

---

## Task List

---

### T1 — Create TranslationBridge stub

**Maps to**: FR-6
**Owner**: Claude
**Effort**: Small

Create `TranslateCall/App/TranslationBridge.swift`:

```swift
struct TranslationBridge: View {
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
        // Full wiring in F2.x
    }
}
```

Embed in `TranslateCallApp` inside a `ZStack` behind `ContentView`.

**Acceptance**: App compiles. TranslationBridge is invisible at runtime.

---

### T2 — Implement AudioViewModel

**Maps to**: AD-1, FR-2, FR-3, FR-5
**Owner**: Claude
**Effort**: Medium

Create `TranslateCall/Features/Main/AudioViewModel.swift`:

- Holds a `private let audioManager: AudioManager`
- Mirrors `inputDevices`, `outputDevices`, `selectedInput`, `selectedOutput`, `inputLevel`, `isCapturing` via Combine `assign(to:)`
- Adds `isStarting: Bool` and `errorAlert: AlertItem?`
- Implements `toggleCapture() async` with error handling (permissionDenied → openSettings alert, other → generic alert)
- Implements `selectInput(_ device:)` and `selectOutput(_ device:)` (call AudioManager, catch errors)
- Provides `static func preview(capturing: Bool, level: Float) -> AudioViewModel` factory for previews

**Acceptance**: All `@Published` properties update correctly when AudioManager changes. Preview factory returns a usable instance.

---

### T3 — Implement DeviceSectionView

**Maps to**: FR-2
**Owner**: Claude
**Effort**: Small

Create `TranslateCall/Features/Main/DeviceSectionView.swift`:

- Two `Picker` rows: "Microphone" (input) and "Output"
- Bound to `vm.selectedInput` / `vm.selectedOutput`
- `onChange` calls `vm.selectInput` / `vm.selectOutput`
- Disabled + "No devices found" when list is empty

**Acceptance**: `#Preview` shows both pickers with mock devices. Selecting an option in preview doesn't crash.

---

### T4 — Implement LevelMeterView

**Maps to**: FR-4
**Owner**: Claude
**Effort**: Small

Create `TranslateCall/Features/Main/LevelMeterView.swift`:

- `GeometryReader` fills a `RoundedRectangle` proportionally to `level` mapped from -60..0 dBFS → 0..1
- Color: green (< -12 dBFS), yellow (-12..-3), red (≥ -3)
- Empty / minimal when `isActive == false`
- Background track in secondary color

**Acceptance**:
- `#Preview` with `level: -12, isActive: true` shows a half-filled green bar
- `#Preview` with `isActive: false` shows empty bar

---

### T5 — Implement StatusBadgeView

**Maps to**: FR-5
**Owner**: Claude
**Effort**: Small

Create `TranslateCall/Features/Main/StatusBadgeView.swift`:

- Grey circle + "Idle" when `isCapturing == false`
- Green circle + "Listening" when `isCapturing == true`
- Green circle uses `withAnimation` pulse (scale 1.0→1.3→1.0, repeat forever)

**Acceptance**: `#Preview` shows both states side by side.

---

### T6 — Implement CaptureButtonView

**Maps to**: FR-3
**Owner**: Claude
**Effort**: Small

Create `TranslateCall/Features/Main/CaptureButtonView.swift`:

- Single `Button` calling `vm.toggleCapture()` via `Task { await vm.toggleCapture() }`
- Label: SF Symbol `mic.fill` + "Start" when idle; `stop.fill` + "Stop" when capturing
- Disabled when `vm.isStarting == true`
- Prominent button style (`.buttonStyle(.borderedProminent)`)

**Acceptance**: Button is disabled during async start. Label switches correctly.

---

### T7 — Implement ContentView

**Maps to**: FR-1, FR-2, FR-3, FR-4, FR-5
**Owner**: Claude
**Effort**: Small

Replace stub `ContentView.swift` with real layout:

```
VStack(spacing: 20) {
    DeviceSectionView
    Divider
    StatusBadgeView + LevelMeterView (HStack)
    CaptureButtonView
}
.frame(width: 480, height: 300)
.padding()
.alert(item: $vm.errorAlert) { ... }
```

`@EnvironmentObject var vm: AudioViewModel`

**Acceptance**: `#Preview` renders full layout with mock data. No hardcoded strings (use constants or localized).

---

### T8 — Wire TranslateCallApp

**Maps to**: FR-1, FR-6
**Owner**: Claude
**Effort**: Small

Update `TranslateCallApp.swift`:

- Instantiate `AudioViewModel` as `@StateObject`
- Inject into environment
- Embed `TranslationBridge` in `ZStack`
- Apply `.windowResizability(.contentSize)`

**Acceptance**: App launches, window is 480×300, non-resizable, AudioManager initializes.

---

### T9 — Validate acceptance criteria

**Maps to**: All requirements
**Owner**: Both
**Effort**: Small

Manual checklist:
- [ ] App launches and shows correct window (480×300, non-resizable)
- [ ] Input and output pickers populate from AudioManager
- [ ] Selecting a device calls the correct AudioManager method
- [ ] Start/Stop button toggles capture and updates label
- [ ] Permission denied shows actionable alert
- [ ] Level meter animates while capturing, empty when idle
- [ ] Status badge shows correct state
- [ ] All `#Preview` blocks render without errors
- [ ] Zero Swift 6 concurrency warnings
- [ ] SwiftLint clean

**Acceptance**: All items checked. F1.3 marked complete. M1 complete.

---

## Dependency Order

```
T1 (TranslationBridge) ─────────────────────────────────────────┐
T2 (AudioViewModel) ──┐                                          │
T3 (DeviceSectionView)─┤                                         │
T4 (LevelMeterView)   ─┼──▶ T7 (ContentView) ──▶ T8 (App) ──▶ T9
T5 (StatusBadgeView)  ─┤
T6 (CaptureButtonView)─┘
```

T1–T6 can be done in parallel.
T7 depends on T2–T6.
T8 depends on T1 and T7.
T9 is last.
