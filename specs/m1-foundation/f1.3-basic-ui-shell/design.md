# F1.3 - Basic UI Shell
## Technical Design

**Feature**: F1.3
**Milestone**: M1 - Foundation
**Status**: COMPLETED — 2026-03-07
**Last Updated**: 2026-03-07

---

## Architecture Decisions

### AD-1: Single ViewModel — AudioViewModel

**Decision**: Introduce `AudioViewModel` (`@MainActor ObservableObject`) as the bridge between `AudioManager` and SwiftUI views.

**Rationale**: `AudioManager` is already `@MainActor` and `ObservableObject`, so it could be injected directly into views. However, wrapping it in a ViewModel keeps view logic (error alerts, async task management, button state) out of `AudioManager` and makes previews trivial — the ViewModel can be initialized with a mock.

**Consequences**: Views observe `AudioViewModel` via `@StateObject` / `@EnvironmentObject`. `AudioManager` stays a pure audio layer with no UI dependencies.

### AD-2: No NavigationStack — single flat window

**Decision**: The M1 window is a single `VStack`-based layout with no navigation.

**Rationale**: TranslateCall in M1 is a utility window, not a multi-screen app. Adding NavigationStack now would be premature. AppKit `NSWindow` sizing is controlled via `.frame(width:height:)` + `windowResizability(.contentSize)` scene modifier.

### AD-3: Level meter as custom Shape

**Decision**: Implement `LevelMeterView` as a simple `GeometryReader` + `Rectangle` fill, not a `ProgressView`.

**Rationale**: `ProgressView` doesn't support per-segment coloring or dBFS mapping. A custom view gives full control with minimal code.

### AD-4: TranslationBridge as a modifier-injected view

**Decision**: `TranslationBridge` is a `Color.clear.frame(width:0, height:0)` view with a `.translationTask` modifier stub, embedded directly in `TranslateCallApp` via `ZStack`.

**Rationale**: PoC1 proved the Translation framework requires a SwiftUI view in the hierarchy with `.translationTask()`. The stub ensures the framework is initialized even before F2.x wires it up.

---

## Component Map

```
TranslateCallApp
├── WindowGroup
│   └── ZStack
│       ├── ContentView                   ← main window
│       │   └── AudioViewModel (@StateObject)
│       │       ├── DeviceSectionView     ← FR-2: device pickers
│       │       ├── LevelMeterView        ← FR-4: level bar
│       │       ├── StatusBadgeView       ← FR-5: dot + label
│       │       └── CaptureButtonView     ← FR-3: start/stop
│       └── TranslationBridge             ← FR-6: invisible stub
```

---

## File Structure

```
TranslateCall/
├── App/
│   ├── TranslateCallApp.swift         ← embed TranslationBridge
│   └── TranslationBridge.swift        ← stub (FR-6)
└── Features/
    └── Main/
        ├── ContentView.swift           ← root layout
        ├── AudioViewModel.swift        ← ViewModel
        ├── DeviceSectionView.swift     ← device pickers (FR-2)
        ├── LevelMeterView.swift        ← level bar (FR-4)
        ├── StatusBadgeView.swift       ← status dot (FR-5)
        └── CaptureButtonView.swift     ← start/stop (FR-3)
```

---

## Public API / Interfaces

### AudioViewModel

```swift
@MainActor
final class AudioViewModel: ObservableObject {

    // Observed from AudioManager
    @Published private(set) var inputDevices: [AudioDevice]
    @Published private(set) var outputDevices: [AudioDevice]
    @Published var selectedInput: AudioDevice?
    @Published var selectedOutput: AudioDevice?
    @Published private(set) var inputLevel: Float      // RMS dBFS (-160..0)
    @Published private(set) var isCapturing: Bool

    // UI-specific state
    @Published private(set) var isStarting: Bool       // button disabled while async starts
    @Published var errorAlert: AlertItem?              // non-nil → show alert

    struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let action: AlertAction?

        enum AlertAction {
            case openSettings
        }
    }

    // Actions
    func toggleCapture() async
    func selectInput(_ device: AudioDevice)
    func selectOutput(_ device: AudioDevice)
}
```

### LevelMeterView

```swift
struct LevelMeterView: View {
    var level: Float        // dBFS, -160..0
    var isActive: Bool      // if false, show empty bar

    // Internal: maps level to 0..1, colors segments
}
```

### StatusBadgeView

```swift
struct StatusBadgeView: View {
    var isCapturing: Bool
    // Shows pulsing green dot + "Listening" or grey dot + "Idle"
}
```

### TranslationBridge (stub)

```swift
struct TranslationBridge: View {
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            // .translationTask stub — full wiring in F2.x
    }
}
```

---

## Layout Sketch

```
┌──────────────────────────────────────────────┐  ← 480 pts
│  TranslateCall                               │
├──────────────────────────────────────────────┤
│                                              │  ↑
│  Microphone  [ Built-in Microphone      ▾ ] │  │
│  Output      [ BlackHole 2ch            ▾ ] │  │
│                                              │  300
│  ●  Listening                                │  pts
│  ████████████████░░░░░░░░░░  -12 dBFS        │  │
│                                              │  │
│              [ ■ Stop ]                      │  │
│                                              │  ↓
└──────────────────────────────────────────────┘
```

---

## Key Implementation Notes

### Window sizing

```swift
// In TranslateCallApp:
WindowGroup {
    ContentView()
        .environmentObject(AudioViewModel())
}
.windowResizability(.contentSize)
// ContentView sets .frame(width: 480, height: 300)
```

### Binding device pickers to ViewModel

```swift
Picker("Microphone", selection: $vm.selectedInput) {
    ForEach(vm.inputDevices) { device in
        Text(device.name).tag(Optional(device))
    }
}
.onChange(of: vm.selectedInput) { _, new in
    if let device = new { vm.selectInput(device) }
}
```

### toggleCapture async handling

```swift
func toggleCapture() async {
    if isCapturing {
        audioManager.stopCapture()
    } else {
        isStarting = true
        defer { isStarting = false }
        do {
            try await audioManager.startCapture()
        } catch AudioError.permissionDenied {
            errorAlert = AlertItem(
                title: "Microphone Access Required",
                message: "TranslateCall needs microphone access. Open System Settings to allow it.",
                action: .openSettings
            )
        } catch {
            errorAlert = AlertItem(title: "Error", message: error.localizedDescription, action: nil)
        }
    }
}
```

### Level meter dBFS mapping

```swift
// Map -60..0 dBFS → 0..1 fill fraction
let minDB: Float = -60
let fraction = Double(max(minDB, level) - minDB) / Double(0 - minDB)
// Color thresholds: < -12 → green, < -3 → yellow, else → red
```

### Binding AudioManager state to ViewModel

AudioManager is `@MainActor ObservableObject`. AudioViewModel holds a reference and mirrors its `@Published` properties using `Combine`:

```swift
audioManager.$inputDevices
    .assign(to: &$inputDevices)

audioManager.$inputLevel
    .assign(to: &$inputLevel)
// etc.
```

---

## Preview Strategy

Each view has a `#Preview` with static mock data:

```swift
#Preview("Capturing") {
    ContentView()
        .environmentObject(AudioViewModel.preview(capturing: true, level: -12))
}

#Preview("Idle") {
    ContentView()
        .environmentObject(AudioViewModel.preview(capturing: false))
}
```

`AudioViewModel.preview(...)` is a static factory that returns a pre-configured instance with mock devices and no real `AudioManager`.
