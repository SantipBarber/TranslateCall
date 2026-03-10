# F5.2 – UX Polish: Design

**Milestone**: M5 – Beta Release
**Feature**: F5.2 – UX Polish
**Status**: DRAFT – Pending Gate 2 Review
**Date**: 2026-03-10

---

## 1. Architecture Overview

```
TranslateCallApp / AppDelegate
  └─ MenuBarController (@MainActor)
       ├─ NSStatusItem
       ├─ NSPopover
       │    └─ NSHostingView<MenuBarPopoverView>
       └─ observes AudioViewModel (via Combine)

AudioManager (MODIFY)
  ├─ deviceUID(for: AudioDeviceID) → String?   (new helper)
  ├─ restoreDeviceSelections()                  (new, called in init)
  └─ persist on selectedInput/Output change     (new Combine sink)

AudioViewModel (MODIFY)
  └─ muteTurn()                                 (new: suppress next STT result)

Features/MenuBar/
  └─ MenuBarPopoverView.swift                   (new SwiftUI view)
```

---

## 2. U1 — Menu Bar Status Item

### 2.1 `MenuBarController`

```swift
// Features/MenuBar/MenuBarController.swift (CREATE)

@MainActor
final class MenuBarController {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellable: AnyCancellable?

    // Injected from AppContainer
    private let viewModel: AudioViewModel

    init(viewModel: AudioViewModel) {
        self.viewModel = viewModel
        setupStatusItem()
        observeState()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }

        button.image = NSImage(systemSymbolName: "mic.slash", accessibilityDescription: "TranslateCall")
        button.image?.isTemplate = true
        button.action = #selector(statusItemLeftClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self

        // Set up popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 220)
        popover.behavior = .transient  // auto-closes on outside click
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(viewModel: viewModel)
        )
        self.popover = popover
    }

    @objc private func statusItemLeftClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu(sender)
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    private func showContextMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()
        let toggleTitle = viewModel.isCapturing ? "Stop Translation" : "Start Translation"
        menu.addItem(NSMenuItem(title: toggleTitle, action: #selector(toggleCapture), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Main Window", action: #selector(openMainWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit TranslateCall", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil  // reset so left-click shows popover next time
    }

    @objc private func toggleCapture() {
        viewModel.toggleCapture()
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    private func observeState() {
        cancellable = viewModel.$halfDuplexState
            .combineLatest(viewModel.$isCapturing)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, isCapturing in
                self?.updateIcon(halfDuplexState: state, isCapturing: isCapturing)
            }
    }

    private func updateIcon(halfDuplexState: HalfDuplexState, isCapturing: Bool) {
        let symbolName: String
        switch (isCapturing, halfDuplexState) {
        case (false, _):      symbolName = "mic.slash"
        case (true, .speaking), (true, .transitioning): symbolName = "waveform"
        case (true, _):       symbolName = "mic"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "TranslateCall")
        statusItem?.button?.image?.isTemplate = true
    }
}
```

> **Note**: `HalfDuplexState` must be accessible from `AudioViewModel`. It is already exposed as `halfDuplexState: HalfDuplexState` via the `bindCoordinator()` binding in `AudioViewModel`. Verify this property is `@Published`.

### 2.2 `MenuBarPopoverView`

```swift
// Features/MenuBar/MenuBarPopoverView.swift (CREATE)

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: AudioViewModel

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "waveform.and.mic")
                Text("TranslateCall").font(.headline)
                Spacer()
                Text(appVersion).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            // Status
            StatusBadgeView(halfDuplexState: viewModel.halfDuplexState)

            // Language pair (read-only)
            HStack {
                Text(viewModel.sourceLanguageDisplay).font(.subheadline)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                Text(viewModel.targetLanguageDisplay).font(.subheadline)
            }

            Divider()

            // Controls
            Button(viewModel.isCapturing ? "Stop Translation" : "Start Translation") {
                viewModel.toggleCapture()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Open Main Window") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .padding(16)
        .frame(width: 280)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
}
```

**`AudioViewModel` additions** needed for `MenuBarPopoverView`:
- `var sourceLanguageDisplay: String` — formatted source language name (already available via `languagePairManager`)
- `var targetLanguageDisplay: String` — formatted target language name

### 2.3 Integration into App Entry Point

```swift
// TranslateCallApp.swift (MODIFY)

@main
struct TranslateCallApp: App {
    @StateObject private var container = AppContainer()
    // NEW:
    @State private var menuBarController: MenuBarController?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(container.audioViewModel)
                // ... existing env objects ...
                .onAppear {
                    // Create MenuBarController once (after container is ready)
                    if menuBarController == nil {
                        menuBarController = MenuBarController(viewModel: container.audioViewModel)
                    }
                }
        }
    }
}
```

> **Alternative**: Create `MenuBarController` in `AppContainer` (cleaner DI). Prefer this if `container` init is synchronous and `@StateObject` lifecycle allows it.

---

## 3. U2 — Device Selection Persistence

### 3.1 Device UID Reading

Core Audio device UID is read via `AudioObjectGetPropertyData` with selector `kAudioDevicePropertyDeviceUID`:

```swift
// Core/Audio/AudioDevice.swift (MODIFY — add class method)

extension AudioDevice {
    /// Returns the stable UID string for the given device ID.
    static func uid(for deviceID: AudioDeviceID) -> String? {
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        return status == noErr ? (uid as String) : nil
    }
}
```

### 3.2 `AudioManager` Persistence

```swift
// Core/Audio/AudioManager.swift (MODIFY)

@MainActor
final class AudioManager: ObservableObject {

    // MARK: - UserDefaults keys (new)
    private static let inputDeviceUIDKey  = "tlk.input.deviceUID"
    private static let outputDeviceUIDKey = "tlk.output.deviceUID"

    // MARK: - Init (MODIFY)

    init() {
        // ... existing init code ...
        restoreDeviceSelections()
    }

    // MARK: - New: restoreDeviceSelections

    private func restoreDeviceSelections() {
        let savedInputUID  = UserDefaults.standard.string(forKey: Self.inputDeviceUIDKey)
        let savedOutputUID = UserDefaults.standard.string(forKey: Self.outputDeviceUIDKey)

        if let uid = savedInputUID,
           let device = availableInputDevices.first(where: { AudioDevice.uid(for: $0.deviceID) == uid }) {
            selectedInput = device
        }
        // else: keep default (first available) — no error

        if let uid = savedOutputUID,
           let device = availableOutputDevices.first(where: { AudioDevice.uid(for: $0.deviceID) == uid }) {
            selectedOutput = device
        }
    }

    // MARK: - Persist on selection change (MODIFY setters or add Combine sink)

    // Option A: Modify the @Published property setter (not directly possible with @Published)
    // Option B: Add didSet-style logic via Combine sink in init after super:

    private var persistenceCancellables = Set<AnyCancellable>()

    private func setupPersistence() {
        $selectedInput
            .dropFirst()  // skip initial value (set before restoreDeviceSelections)
            .sink { [weak self] device in
                guard let self, let device else { return }
                if let uid = AudioDevice.uid(for: device.deviceID) {
                    UserDefaults.standard.set(uid, forKey: Self.inputDeviceUIDKey)
                }
            }
            .store(in: &persistenceCancellables)

        $selectedOutput
            .dropFirst()
            .sink { [weak self] device in
                guard let self, let device else { return }
                if let uid = AudioDevice.uid(for: device.deviceID) {
                    UserDefaults.standard.set(uid, forKey: Self.outputDeviceUIDKey)
                }
            }
            .store(in: &persistenceCancellables)
    }
}
```

Call `setupPersistence()` at end of `init()`, after `restoreDeviceSelections()`.

> **Note**: `selectedInput`/`selectedOutput` are `@Published var` — they work with Combine subscriptions. The `.dropFirst()` skips the initial assignment from `restoreDeviceSelections()` so we don't unnecessarily re-write the same UID on launch.

---

## 4. U3 — Keyboard Shortcuts

### 4.1 Start/Stop Shortcut (`Cmd+Shift+T`)

Applied directly to the "Start" / "Stop" button in `ContentView` and `MenuBarPopoverView`:

```swift
// In ContentView and MenuBarPopoverView:
Button(viewModel.isCapturing ? "Stop" : "Start") {
    viewModel.toggleCapture()
}
.keyboardShortcut("t", modifiers: [.command, .shift])
```

SwiftUI `.keyboardShortcut()` scopes the shortcut to the window/scene that contains the button. When the main window is focused, `Cmd+Shift+T` triggers the main window button. When the popover is focused, it triggers the popover button. Both call the same `viewModel.toggleCapture()`.

### 4.2 Mute Turn Shortcut (`Cmd+Shift+M`)

```swift
// In ContentView:
Button("Mute Turn") {
    viewModel.muteTurn()
}
.keyboardShortcut("m", modifiers: [.command, .shift])
.disabled(!viewModel.isCapturing)
```

`AudioViewModel.muteTurn()` implementation:
```swift
// Features/Main/AudioViewModel.swift (MODIFY)

/// Suppresses the next outgoing STT result from being translated and spoken.
/// Used as a "push-to-skip" for the current utterance.
func muteTurn() {
    guard isCapturing else { return }
    coordinator.suppressNextOutgoingTurn()
}
```

`AudioCoordinator.suppressNextOutgoingTurn()`:
```swift
// Core/Audio/AudioCoordinator.swift (MODIFY)

/// Suppresses exactly one outgoing translation cycle.
/// The next speech segment detected by VAD will be transcribed but not translated/spoken.
private var suppressNextOutgoingTurn: Bool = false

func suppressNextOutgoingTurn() {
    suppressNextOutgoingTurn = true
}

// In handleOutgoingTranslation (or equivalent):
func handleOutgoingTranslation(text: String) async {
    if suppressNextOutgoingTurn {
        suppressNextOutgoingTurn = false
        return  // skip this utterance
    }
    // ... existing translation + TTS logic ...
}
```

> **Note**: This is a single-turn suppression. It resets after one use, regardless of whether any speech was detected. This is the simplest implementation; more sophisticated push-to-mute is deferred.

---

## 5. File Map

| File | Change | Notes |
|------|--------|-------|
| `Features/MenuBar/MenuBarController.swift` | **CREATE** | NSStatusItem + NSPopover lifecycle |
| `Features/MenuBar/MenuBarPopoverView.swift` | **CREATE** | SwiftUI popover content |
| `App/TranslateCallApp.swift` | **MODIFY** | Create MenuBarController on appear |
| `Core/Audio/AudioDevice.swift` | **MODIFY** | Add `static func uid(for:) -> String?` |
| `Core/Audio/AudioManager.swift` | **MODIFY** | `restoreDeviceSelections()`, `setupPersistence()`, Combine sinks |
| `Features/Main/AudioViewModel.swift` | **MODIFY** | Add `muteTurn()`, `sourceLanguageDisplay`, `targetLanguageDisplay` |
| `Core/Audio/AudioCoordinator.swift` | **MODIFY** | Add `suppressNextOutgoingTurn()` and flag |
| `TranslateCallTests/AudioManagerTests.swift` | **MODIFY** | Add device UID persistence tests |

---

## 6. `AudioViewModel` Display Helpers

```swift
// Features/Main/AudioViewModel.swift (add computed properties)

var sourceLanguageDisplay: String {
    languagePairManager.selectedSource?
        .localizedString(forLanguageCode: languagePairManager.selectedSource?.identifier ?? "")
        ?? languagePairManager.selectedSource?.identifier
        ?? "—"
}

var targetLanguageDisplay: String {
    // Same pattern for target
}
```

Simpler alternative — use `Locale.current.localizedString(forIdentifier:)`:
```swift
var sourceLanguageDisplay: String {
    guard let locale = languagePairManager.selectedSource else { return "—" }
    return Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
}
```

---

## 7. Test Strategy

### `AudioManagerTests` — new device UID tests

```swift
// Cannot test UID reading in unit tests (requires real hardware device IDs)
// Test the restoration logic indirectly:

// deviceUIDRestorationSkipsIfNoSavedUID — init with no UserDefaults key, assert selectedInput == default
// deviceUIDRestorationFallsBackWhenUIDNotFound — write unknown UID, assert selectedInput == first available
// deviceUIDPersistedOnSelectionChange — mock: set selectedInput, check UserDefaults written
```

Since `AudioObjectGetPropertyData` requires real CoreAudio, the UID helper function cannot be unit tested. Test the persistence/restoration logic by injecting a test `UserDefaults` suite and mocking the UID lookup via a testable protocol or closure injection.

`MenuBarController` is not unit-tested (AppKit UI components); covered by manual smoke testing.

---

## 8. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| `NSStatusItem` conflicts with SwiftUI app lifecycle | Low | Medium | Use `@State private var menuBarController` stored in `TranslateCallApp`; create in `.onAppear` ensures correct timing |
| `Cmd+Shift+T` conflicts with system shortcut | Low | Low | Check macOS default shortcuts; `Cmd+Shift+T` is used by some apps but not system-wide |
| Device UID not stable across major macOS updates | Very Low | Low | UIDs are stable per Apple docs; fallback to first available on mismatch |
| `suppressNextOutgoingTurn` flag never reset if no speech follows | Low | Low | Flag is reset after each call to `handleOutgoingTranslation` — if no speech comes, flag expires on next `stop()` call |
| `NSPopover` and SwiftUI state sharing not updating | Medium | Medium | Use `@ObservedObject` in `MenuBarPopoverView`; `AudioViewModel` must be `@MainActor ObservableObject` — already is |

---

*End of F5.2 Design — Gate 2 Review Pending*
