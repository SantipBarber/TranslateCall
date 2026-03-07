# F1.3 - Basic UI Shell
## Requirements

**Feature**: F1.3
**Milestone**: M1 - Foundation
**Status**: COMPLETED — 2026-03-07
**Last Updated**: 2026-03-07

---

## Context

F1.3 provides the minimal macOS UI that ties together the AudioManager (F1.2) with user controls. The window lets the user select input/output devices, start/stop audio capture, and see the live input level meter. No translation logic yet — this is purely the audio control surface that will serve as the shell for all future features.

---

## Functional Requirements

### FR-1: Window and Layout

- WHEN the app launches THEN it SHALL display a single window with a fixed size appropriate for a utility app (≈ 480×300 pts).
- The window SHALL have a title "TranslateCall".
- The window SHALL NOT be resizable in M1 (simplicity first).

### FR-2: Device Selection

- WHEN the app launches THEN it SHALL display a Picker (dropdown) for input device labeled "Microphone".
- WHEN the app launches THEN it SHALL display a Picker (dropdown) for output device labeled "Output".
- WHEN the user selects a device in either picker THEN the corresponding `AudioManager.selectInput` or `selectOutput` SHALL be called.
- WHEN `AudioManager.inputDevices` or `outputDevices` changes THEN the pickers SHALL update automatically.
- IF no devices are available THEN the picker SHALL show "No devices found" and be disabled.

### FR-3: Start / Stop Capture

- WHEN the app displays THEN it SHALL show a single button to start audio capture.
- WHEN capture is not active THEN the button SHALL read "Start" (or equivalent icon + label).
- WHEN capture is active THEN the button SHALL read "Stop" (or equivalent icon + label).
- WHEN the user taps Start THEN `AudioManager.startCapture()` SHALL be called asynchronously.
- WHEN the user taps Stop THEN `AudioManager.stopCapture()` SHALL be called.
- WHILE capture is starting THEN the button SHALL be disabled to prevent double-tap.
- IF `startCapture()` throws `permissionDenied` THEN the app SHALL show an alert explaining microphone access is required with a button to open System Settings.
- IF `startCapture()` throws any other error THEN the app SHALL show an alert with the error message.

### FR-4: Level Meter

- WHILE capture is active THEN the UI SHALL display a horizontal level meter showing `AudioManager.inputLevel` (RMS dBFS).
- The meter SHALL span from -60 dBFS (silence, left) to 0 dBFS (full scale, right).
- The meter SHALL update visually at the rate published by AudioManager (≥ 10 Hz).
- WHEN capture is not active THEN the meter SHALL appear empty / at minimum.
- The meter color SHALL be green for normal levels (-60 to -12 dBFS) and yellow/amber for loud levels (-12 to -3 dBFS) and red for clipping (> -3 dBFS).

### FR-5: Status Indicator

- The UI SHALL show a small status badge:
  - Grey dot + "Idle" when capture is not active
  - Green pulsing dot + "Listening" when capture is active

### FR-6: TranslationBridge placeholder

- The app entry point (`TranslateCallApp`) SHALL embed an invisible `TranslationBridge` view in the window hierarchy so the Translation framework is initialized at launch (required by PoC1).
- The `TranslationBridge` view in M1 SHALL be a stub (empty `Color.clear` view with `translationTask` modifier) — full wiring comes in F2.x.

---

## Non-Functional Requirements

### NFR-1: SwiftUI-only
- All UI SHALL be implemented in SwiftUI. No AppKit views in F1.3.

### NFR-2: Responsiveness
- UI interactions (button taps, picker changes) SHALL feel immediate (< 16ms frame time).

### NFR-3: Swift 6 Concurrency
- All UI state SHALL be bound to `@MainActor`.
- No data races — strict concurrency must remain clean.

### NFR-4: Preview support
- All views SHALL have `#Preview` blocks with mock data (no real AudioManager needed in previews).

---

## Out of Scope (F1.3)

- Translation UI (language pickers, transcript view) → F3.x
- VAD visualization → F2.1
- Settings panel → F5.x
- Menu bar icon → F5.x
- BlackHole routing toggle → F4.1

---

## Acceptance Criteria

- [ ] App launches and shows correct window (480×300, non-resizable)
- [ ] Input and output pickers populate from AudioManager
- [ ] Selecting a device calls the correct AudioManager method
- [ ] Start/Stop button toggles capture and updates label
- [ ] Permission denied shows an actionable alert
- [ ] Level meter animates while capturing, is empty when idle
- [ ] Status badge shows correct state
- [ ] All `#Preview` blocks render without a real AudioManager
- [ ] Zero Swift 6 concurrency warnings
- [ ] SwiftLint clean
