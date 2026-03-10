# F5.2 – UX Polish

**Milestone**: M5 – Beta Release
**Feature**: F5.2 – UX Polish
**Status**: DRAFT – Pending Gate 1 Review
**Date**: 2026-03-10
**Depends on**: F5.1 (stability fixes)

---

## 1. Context & Motivation

After M4, TranslateCall is functionally complete but has usability gaps that will frustrate beta testers and make the product feel unfinished:

1. **No menu bar presence**: The app requires focus to use. During a video call, the user must switch away from Zoom/Teams to interact with TranslateCall. A menu bar status item solves this.
2. **Device selection lost on restart**: The user must re-select their microphone and output device every launch. This is particularly frustrating since the setup wizard already guides them through device configuration.
3. **No keyboard shortcuts**: Starting/stopping translation requires mouse interaction. Users on calls need a quick way to toggle the pipeline without switching app focus.

These three features are the minimum UX quality bar for a credible beta release.

---

## 2. Scope

**In scope for F5.2**:
- **U1: Menu bar status item** — NSStatusItem showing current state (idle/listening/speaking); left-click shows a compact popover with Start/Stop control and status; right-click shows a context menu
- **U2: Device selection persistence** — Save selected input and output device IDs to `UserDefaults`; restore on launch if device is still present
- **U3: In-app keyboard shortcuts** — `Cmd+Shift+T` to toggle Start/Stop; `Cmd+Shift+M` to toggle mute (suppress outgoing for one turn)

**Out of scope for F5.2**:
- Global (system-wide) keyboard shortcuts (requires Accessibility permission — deferred to F5.3 or M6)
- Making TranslateCall a login item / launch-at-startup (M6)
- Removing the Dock icon / pure menu bar app (LSUIElement) — too disruptive for M5 beta; users need to find the app while testing
- Settings window (a dedicated preferences pane for advanced configuration — M6)
- Multiple language pair presets (M6)

---

## 3. Functional Requirements

### 3.1 Menu Bar Status Item (U1)

**FR-5.2.1** WHEN the app launches THEN an `NSStatusItem` SHALL appear in the macOS menu bar with a template icon that reflects the current pipeline state.

**FR-5.2.2** The status item icon SHALL reflect the following states:
- Idle (session stopped): microphone SF Symbol — `"mic.slash"` (template)
- Listening (session active, VAD in silence): microphone SF Symbol — `"mic"` (template)
- Speaking / translating (VAD triggered): waveform SF Symbol — `"waveform"` (template)

**FR-5.2.3** WHEN the user left-clicks the status item THEN a popover SHALL appear containing:
- App name + version string (compact header)
- Status badge (same as `StatusBadgeView` in main window)
- Language pair display (source → target, read-only)
- Start/Stop button (primary action)
- "Open Main Window" link/button

**FR-5.2.4** WHEN the user right-clicks the status item THEN a context menu SHALL appear with:
- "Start Translation" / "Stop Translation" (toggle)
- Separator
- "Open Main Window"
- Separator
- "Quit TranslateCall"

**FR-5.2.5** WHEN the user clicks "Open Main Window" (from popover or menu) THEN the main window SHALL be brought to front and given focus.

**FR-5.2.6** The popover SHALL close automatically when the user clicks outside it.

**FR-5.2.7** WHEN the pipeline state changes (start/stop/VAD trigger) THEN the status item icon SHALL update within 200ms.

**FR-5.2.8** The status item SHALL be visible regardless of whether the main window is open or closed.

### 3.2 Device Selection Persistence (U2)

**FR-5.2.9** WHEN the user selects an input (microphone) device THEN `AudioManager` SHALL persist the device's Core Audio UID string to `UserDefaults` key `"tlk.input.deviceUID"`.

**FR-5.2.10** WHEN the user selects an output device THEN `AudioManager` SHALL persist the device's Core Audio UID string to `UserDefaults` key `"tlk.output.deviceUID"`.

**FR-5.2.11** WHEN the app launches THEN `AudioManager` SHALL attempt to restore the last selected input device by matching the saved UID against `availableInputDevices`.

**FR-5.2.12** WHEN the app launches THEN `AudioManager` SHALL attempt to restore the last selected output device by matching the saved UID against `availableOutputDevices`.

**FR-5.2.13** IF the previously selected device is no longer present (unplugged or unavailable) THEN `AudioManager` SHALL silently fall back to the system default device without error, and the saved UID SHALL be cleared.

**FR-5.2.14** The device UID SHALL be used for persistence (not device name or ID) because UIDs are stable across system restarts while device IDs may change.

### 3.3 Keyboard Shortcuts (U3)

**FR-5.2.15** WHEN the main window or menu bar popover is focused AND the user presses `Cmd+Shift+T` THEN the pipeline SHALL toggle (Start if stopped, Stop if active).

**FR-5.2.16** WHEN the main window or menu bar popover is focused AND the user presses `Cmd+Shift+M` THEN the outgoing microphone capture SHALL be muted for the current utterance (suppresses next STT segment from being translated and spoken).

**FR-5.2.17** Keyboard shortcuts SHALL be declared via SwiftUI `.keyboardShortcut()` modifier on the relevant buttons, scoped to the active window/popover — NOT system-wide global hotkeys.

**FR-5.2.18** WHEN the pipeline is stopped AND the user presses `Cmd+Shift+M` THEN nothing SHALL happen (mute has no effect when not running).

---

## 4. Non-Functional Requirements

**NFR-5.2.1** The menu bar popover SHALL open within 100ms of the status item click.

**NFR-5.2.2** Device UID persistence SHALL NOT block the app launch; it SHALL complete synchronously in the `AudioManager` init (reading `UserDefaults` is fast).

**NFR-5.2.3** The status item SHALL NOT add measurable CPU usage — icon updates use `NSImage` template rendering, no animation.

**NFR-5.2.4** All `UserDefaults` keys introduced in F5.2 SHALL use the `"tlk."` prefix (consistent with existing keys).

**NFR-5.2.5** Adding the status item SHALL NOT require new entitlements.

---

## 5. Constraints

**C-5.2.1** `NSStatusItem` is AppKit, not SwiftUI. The popover content SHALL be a SwiftUI view wrapped in `NSHostingView` and presented via `NSPopover`. This is the standard macOS pattern.

**C-5.2.2** Core Audio device UIDs are available via `kAudioDevicePropertyDeviceUID` — the `AudioDevice` model already reads device IDs; UID reading uses the same `AudioObjectGetPropertyData` API with a different `AudioObjectPropertySelector`.

**C-5.2.3** The `Cmd+Shift+M` mute shortcut is a coarse suppression (skip next STT result). Full utterance-level mute (suppress ongoing capture) requires `AudioCoordinator` API changes and is out of scope; this is best-effort for M5.

**C-5.2.4** The status item is created on the main thread in `AppDelegate` or `TranslateCallApp` init. It persists for the app lifetime.

---

## 6. Acceptance Criteria

| ID | Criterion | Test Method |
|----|-----------|-------------|
| AC-5.2.1 | Status item visible in menu bar on launch | Manual |
| AC-5.2.2 | Status item icon changes on Start/Stop | Manual |
| AC-5.2.3 | Popover opens on left-click with correct content | Manual |
| AC-5.2.4 | Right-click shows context menu with expected items | Manual |
| AC-5.2.5 | "Open Main Window" brings main window to front | Manual |
| AC-5.2.6 | Input device selection saved and restored after restart | Unit: write UID, init AudioManager with mock device list, assert selection restored |
| AC-5.2.7 | Output device selection saved and restored | Same for output |
| AC-5.2.8 | Missing device on restart falls back to default | Unit: write unknown UID, assert selectedInput == first available |
| AC-5.2.9 | `Cmd+Shift+T` toggles pipeline when window focused | Manual |
| AC-5.2.10 | `Cmd+Shift+M` is labelled "Mute Turn" on the Stop button | Manual — verify button has `.keyboardShortcut` modifier |

---

## 7. Open Questions

| # | Question | Owner | Status |
|---|----------|-------|--------|
| OQ-1 | Should the menu bar popover include a compact transcription view (last utterance)? | UX | **Tentative: no — adds complexity; status badge is sufficient for M5** |
| OQ-2 | Should `Cmd+Shift+M` mute the current microphone input immediately (audio-level), or just suppress the next STT result (software)? | Engineering | **Tentative: suppress next STT result (simpler, no AudioCoordinator API change)** |
| OQ-3 | Should the Dock icon remain for M5 beta? | UX | **Yes — LSUIElement makes the app hard to find; defer to M6** |
| OQ-4 | Device UID vs device name for persistence — any edge case where UID is not stable? | Engineering | **UIDs are stable per Apple documentation; use UID** |

---

## 8. Dependencies

| Component | Dependency Type | Notes |
|-----------|----------------|-------|
| `AudioManager` | Modify | Add UID persistence: read UID property, save/restore from UserDefaults |
| `AudioViewModel` | Modify | Expose `toggleCapture()` to menu bar popover; bind status to status item icon |
| `TranslateCallApp` | Modify | Create `NSStatusItem` and `NSPopover` in app lifecycle |
| F5.1 | Prerequisite | Language and device types must be stable before adding menu bar bindings |

---

*End of F5.2 Requirements — Gate 1 Review Pending*
