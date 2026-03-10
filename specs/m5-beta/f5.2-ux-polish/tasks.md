# F5.2 – UX Polish: Tasks

**Milestone**: M5 – Beta Release
**Feature**: F5.2 – UX Polish
**Status**: DRAFT – Pending Gate 3 Review
**Date**: 2026-03-10

---

## Task Summary

| ID | Title | Files | Depends |
|----|-------|-------|---------|
| T1 | Device UID helper in `AudioDevice` | `Core/Audio/AudioDevice.swift` | — |
| T2 | Device selection persistence in `AudioManager` | `Core/Audio/AudioManager.swift` | T1 |
| T3 | `AudioManager` tests for device persistence | `TranslateCallTests/AudioManagerTests.swift` | T2 |
| T4 | `suppressNextOutgoingTurn` in `AudioCoordinator` | `Core/Audio/AudioCoordinator.swift` | — |
| T5 | `muteTurn()` + display helpers in `AudioViewModel` | `Features/Main/AudioViewModel.swift` | T4 |
| T6 | `MenuBarPopoverView` — SwiftUI popover content | `Features/MenuBar/MenuBarPopoverView.swift` | T5 |
| T7 | `MenuBarController` — NSStatusItem + NSPopover | `Features/MenuBar/MenuBarController.swift` | T6 |
| T8 | Wire `MenuBarController` into app entry point | `App/TranslateCallApp.swift` | T7 |
| T9 | Add `Cmd+Shift+T` and `Cmd+Shift+M` shortcuts to `ContentView` | `Features/ContentView.swift` | T5 |
| T10 | Full test suite run + manual smoke + ROADMAP update + commit | — | T1–T9 |

---

## T1 — Device UID Helper in `AudioDevice`

**File**: `TranslateCall/Core/Audio/AudioDevice.swift` (MODIFY)

### Checklist

- [ ] Add `static func uid(for deviceID: AudioDeviceID) -> String?` to `AudioDevice` (or as file-level function if `AudioDevice` is a struct with no static methods pattern)
- [ ] Use `AudioObjectGetPropertyData` with `kAudioDevicePropertyDeviceUID` selector, scope `kAudioObjectPropertyScopeGlobal`, element `kAudioObjectPropertyElementMain`
- [ ] Use `withUnsafeMutablePointer(to: &uid)` pattern (consistent with existing `deviceID(forNameContaining:)` helper)
- [ ] Return `nil` if `AudioObjectGetPropertyData` returns non-`noErr` status
- [ ] Cast result: `uid as String` (CFString → String bridge)
- [ ] Build passes

---

## T2 — Device Selection Persistence in `AudioManager`

**File**: `TranslateCall/Core/Audio/AudioManager.swift` (MODIFY)

### Checklist

- [ ] Add `private static let inputDeviceUIDKey = "tlk.input.deviceUID"` constant
- [ ] Add `private static let outputDeviceUIDKey = "tlk.output.deviceUID"` constant
- [ ] Add `private var persistenceCancellables = Set<AnyCancellable>()` property
- [ ] Add `private func restoreDeviceSelections()`:
  - Read `UserDefaults.standard.string(forKey: inputDeviceUIDKey)` → try to find matching device in `availableInputDevices` by comparing `AudioDevice.uid(for: device.deviceID)` to saved UID
  - If found: `selectedInput = device`; if not found: keep default (first available), clear stale key: `UserDefaults.standard.removeObject(forKey: inputDeviceUIDKey)`
  - Same logic for output
- [ ] Add `private func setupPersistence()`:
  - Subscribe to `$selectedInput.dropFirst()` — on change, get UID and write to `UserDefaults`; if UID nil, remove key
  - Subscribe to `$selectedOutput.dropFirst()` — same for output
  - Store both in `persistenceCancellables`
- [ ] Call `restoreDeviceSelections()` in `init()` after device lists are populated
- [ ] Call `setupPersistence()` in `init()` after `restoreDeviceSelections()`
- [ ] Verify: `$selectedInput.dropFirst()` skips the initial value set by `restoreDeviceSelections()` so we don't double-write the UID on launch
- [ ] Build passes, existing `AudioManagerTests` pass

---

## T3 — `AudioManager` Tests for Device Persistence

**File**: `TranslateCallTests/AudioManagerTests.swift` (MODIFY — add new tests)

### Checklist

> **Note**: `AudioDevice.uid(for:)` requires real CoreAudio and cannot be called in unit tests. Test persistence logic by injecting a test `UserDefaults` and stubbing the UID lookup.
>
> Practical approach: add an `init(defaults:)` parameter to `AudioManager` (test-only; production uses `.standard`), and a `uidProvider: ((AudioDeviceID) -> String?)? = nil` closure for test injection.

- [ ] Add `internal init(defaults: UserDefaults = .standard, uidProvider: ((AudioDeviceID) -> String?)? = nil)` to `AudioManager` — in tests, pass `uidProvider: { deviceID in "uid-\(deviceID)" }` to avoid calling CoreAudio
- [ ] `deviceUIDNoSavedUIDUsesDefault` — init with empty test UserDefaults, assert `selectedInput` is first available device
- [ ] `deviceUIDRestoredWhenFound` — write a UID string to test UserDefaults; inject `uidProvider` that returns that UID for a known device; init; assert `selectedInput` matches that device
- [ ] `deviceUIDStaleClearedWhenDeviceGone` — write a UID that no device matches; init; assert `selectedInput` is default AND UserDefaults key is cleared
- [ ] `deviceUIDPersistedOnSelectionChange` — init with test defaults; change `selectedInput` to a specific device; assert test UserDefaults contains the expected UID from `uidProvider`
- [ ] Build passes, all tests green

---

## T4 — `suppressNextOutgoingTurn` in `AudioCoordinator`

**File**: `TranslateCall/Core/Audio/AudioCoordinator.swift` (MODIFY)

### Checklist

- [ ] Add `@MainActor private var suppressNextOutgoingTurnFlag: Bool = false` property
- [ ] Add `func suppressNextOutgoingTurn()`: sets `suppressNextOutgoingTurnFlag = true`
- [ ] In `handleOutgoingTranslation(text:)` (or equivalent method that receives STT result and initiates translation):
  - At the top: `if suppressNextOutgoingTurnFlag { suppressNextOutgoingTurnFlag = false; return }`
- [ ] In `stop()`: reset flag to `false` (cleanup)
- [ ] Verify: flag is on `@MainActor` — all accesses are on main actor (coordinator is `@MainActor`) — no `nonisolated(unsafe)` needed
- [ ] Build passes, existing `AudioCoordinatorTests` pass

---

## T5 — `muteTurn()` + Display Helpers in `AudioViewModel`

**File**: `TranslateCall/Features/Main/AudioViewModel.swift` (MODIFY)

### Checklist

- [ ] Add `func muteTurn()`:
  - Guard `isCapturing` — return if not active
  - Call `coordinator.suppressNextOutgoingTurn()`
- [ ] Add `var sourceLanguageDisplay: String`:
  - Guard `languagePairManager.selectedSource != nil`; else return `"—"`
  - Return `Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier`
- [ ] Add `var targetLanguageDisplay: String` — same pattern for target
- [ ] Build passes

---

## T6 — `MenuBarPopoverView`

**File**: `TranslateCall/Features/MenuBar/MenuBarPopoverView.swift` (CREATE)

### Checklist

- [ ] Create directory `TranslateCall/Features/MenuBar/` if not present
- [ ] `struct MenuBarPopoverView: View` with `@ObservedObject var viewModel: AudioViewModel`
- [ ] Header `HStack`: `Image(systemName: "waveform.and.mic")` + `Text("TranslateCall").font(.headline)` + `Spacer()` + version string from `Bundle.main`
- [ ] `Divider()`
- [ ] `StatusBadgeView(halfDuplexState: viewModel.halfDuplexState)` — reuse existing component
  - Note: `StatusBadgeView` may need its initializer to accept `halfDuplexState` as a parameter; check current signature; if it reads from `@EnvironmentObject`, pass `viewModel` as env object to `NSHostingController` instead
- [ ] Language pair row: `Text(viewModel.sourceLanguageDisplay)` + arrow icon + `Text(viewModel.targetLanguageDisplay)`
- [ ] `Divider()`
- [ ] Start/Stop `Button` with `.keyboardShortcut("t", modifiers: [.command, .shift])`
  - Title: `viewModel.isCapturing ? "Stop Translation" : "Start Translation"`
  - Action: `viewModel.toggleCapture()`
  - Style: `.borderedProminent`, control size `.large`
- [ ] "Open Main Window" `Button` — plain style, `.foregroundStyle(.tint)`
  - Action: `NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)`
- [ ] `.padding(16)`, `.frame(width: 280)`
- [ ] Preview with a mock `AudioViewModel`
- [ ] Build passes

---

## T7 — `MenuBarController`

**File**: `TranslateCall/Features/MenuBar/MenuBarController.swift` (CREATE)

### Checklist

- [ ] `@MainActor final class MenuBarController` — NOT `ObservableObject` (no need to observe it from SwiftUI)
- [ ] `private var statusItem: NSStatusItem?`
- [ ] `private var popover: NSPopover?`
- [ ] `private var cancellable: AnyCancellable?`
- [ ] `private let viewModel: AudioViewModel`
- [ ] `init(viewModel: AudioViewModel)`: calls `setupStatusItem()` then `observeState()`
- [ ] `setupStatusItem()`:
  - `statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)`
  - Set `button.image` to `NSImage(systemSymbolName: "mic.slash", accessibilityDescription: "TranslateCall")`, `isTemplate = true`
  - Set `button.action = #selector(statusItemClicked(_:))`, `button.sendAction(on: [.leftMouseUp, .rightMouseUp])`, `button.target = self`
  - Create `NSPopover` with `.transient` behavior, content size `NSSize(width: 280, height: 240)`
  - Set `popover.contentViewController = NSHostingController(rootView: MenuBarPopoverView(viewModel: viewModel))`
- [ ] `@objc private func statusItemClicked(_ sender: NSStatusBarButton)`:
  - Check `NSApp.currentEvent?.type` — if `.rightMouseUp` → `showContextMenu(sender)`, else → `togglePopover(sender)`
- [ ] `togglePopover(_ sender:)`:
  - If `popover?.isShown == true`: `popover?.performClose(nil)`
  - Else: `popover?.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)`
- [ ] `showContextMenu(_ sender:)`:
  - Build `NSMenu` with: toggle item, separator, "Open Main Window", separator, "Quit"
  - Set `statusItem?.menu = menu`, `statusItem?.button?.performClick(nil)`, then `statusItem?.menu = nil`
  - Add `@objc func openMainWindow()` and `@objc func toggleCapture()` as menu item selectors
- [ ] `observeState()`:
  - Combine `viewModel.$halfDuplexState` and `viewModel.$isCapturing` via `combineLatest`
  - Update status item icon symbol: stopped → `"mic.slash"`, speaking/transitioning → `"waveform"`, listening → `"mic"`
  - Store in `cancellable`
- [ ] `deinit`: `statusItem?.statusBar?.removeStatusItem(statusItem!)` — or just let system handle it
- [ ] Build passes

---

## T8 — Wire `MenuBarController` into App Entry Point

**File**: `TranslateCall/App/TranslateCallApp.swift` (MODIFY)

### Checklist

- [ ] Add `@State private var menuBarController: MenuBarController?` property to `TranslateCallApp`
- [ ] In `ContentView()` chain, add `.onAppear`:
  ```swift
  .onAppear {
      guard menuBarController == nil else { return }
      menuBarController = MenuBarController(viewModel: container.audioViewModel)
  }
  ```
- [ ] Verify: `MenuBarController` is created once (guard prevents re-creation on view lifecycle resets)
- [ ] Build passes
- [ ] Manual verification: status bar item appears on launch

---

## T9 — Keyboard Shortcuts in `ContentView`

**File**: `TranslateCall/Features/ContentView.swift` (MODIFY)

### Checklist

- [ ] Find the Start/Stop button (or `CaptureButtonView` if it's a separate view)
- [ ] Add `.keyboardShortcut("t", modifiers: [.command, .shift])` to the Start/Stop button
- [ ] Add a "Mute Turn" button (can be subtle — a link-style button or small secondary button) near the Start button:
  ```swift
  Button("Mute Turn") { viewModel.muteTurn() }
      .keyboardShortcut("m", modifiers: [.command, .shift])
      .disabled(!viewModel.isCapturing)
      .buttonStyle(.plain)
      .font(.caption)
      .foregroundStyle(.secondary)
  ```
- [ ] Verify `Cmd+Shift+T` does NOT conflict with any existing shortcut in the codebase
- [ ] Build passes

---

## T10 — Integration + Commit

### Checklist

- [ ] Run full test suite → `** TEST SUCCEEDED **`
- [ ] Manual smoke tests:
  - [ ] Launch app: verify status bar icon appears
  - [ ] Left-click status item: popover opens with correct state
  - [ ] Right-click status item: context menu shown
  - [ ] Start translation from popover: icon changes to `"mic"`, main window button state updates
  - [ ] Stop translation from main window: icon returns to `"mic.slash"`, popover shows "Start Translation"
  - [ ] Select microphone device, quit app, relaunch: same device selected
  - [ ] Select output device, quit, relaunch: same device selected
  - [ ] Unplug a USB audio device, relaunch: fallback to default, no crash
  - [ ] Press `Cmd+Shift+T` with main window focused: toggles pipeline
  - [ ] Press `Cmd+Shift+M` during active session: next utterance skipped (verify via console log or UI)
- [ ] `git add` all new and modified files
- [ ] `git commit`: `"Implement F5.2 — menu bar status item, device persistence, keyboard shortcuts"`
- [ ] Update `ROADMAP.md`: mark F5.2 as COMPLETED with date
- [ ] Update `memory/MEMORY.md`: add F5.2 key decisions

---

## Implementation Notes

### `StatusBadgeView` in `NSHostingController`

If `StatusBadgeView` reads from `@EnvironmentObject var viewModel: AudioViewModel`, the `NSHostingController` must inject the environment:

```swift
let rootView = MenuBarPopoverView(viewModel: viewModel)
    .environmentObject(viewModel)
popover.contentViewController = NSHostingController(rootView: rootView)
```

If `StatusBadgeView` accepts its state as a parameter (e.g., `StatusBadgeView(state: viewModel.halfDuplexState)`), no environment injection needed. Check current implementation and adjust accordingly.

### `NSStatusItem` Cocoa Target

`@objc` methods on `MenuBarController` require it to be an `NSObject` subclass if used as menu item selectors. Two options:
1. Make `MenuBarController: NSObject` — simplest
2. Use closures instead of `#selector`: `NSMenuItem(title: "...", action: nil, keyEquivalent: "")` + manually trigger via a wrapper

**Recommended**: Make `MenuBarController: NSObject`. Add `super.init()` call in `init`. The `@MainActor` attribute is still compatible with `NSObject`.

```swift
@MainActor
final class MenuBarController: NSObject {
    // ...
    init(viewModel: AudioViewModel) {
        self.viewModel = viewModel
        super.init()
        setupStatusItem()
        observeState()
    }
}
```

### Device UID and `dropFirst()`

The Combine `.dropFirst()` on `$selectedInput` skips the first value emitted when the publisher is subscribed to. Since `selectedInput` is set during `restoreDeviceSelections()` (which runs before `setupPersistence()`), the `.dropFirst()` must be set up AFTER `restoreDeviceSelections()` completes. The `init()` call sequence must be:

```swift
init() {
    // 1. Build device lists
    // 2. restoreDeviceSelections() — sets selectedInput/Output from UserDefaults
    // 3. setupPersistence() — subscribes with .dropFirst() — skips the just-set value
}
```

If `setupPersistence()` is called before `restoreDeviceSelections()`, the `.dropFirst()` would skip the restoration assignment and then immediately write the restored UID back — which is harmless but wasteful.

### Mute Turn — Console Log for Verification

Add a `Logger` call in `AudioCoordinator.suppressNextOutgoingTurn()` and in the guard that executes the skip:

```swift
Logger(subsystem: "TranslateCall", category: "AudioCoordinator")
    .debug("Suppressing next outgoing utterance")
```

This lets testers verify the feature works without a visible UI change.

---

*End of F5.2 Tasks — Gate 3 Review Pending*
