# M9 UI first-run setup assistant — Design

> Status: APPROVED (2026-11-17). Implements `requirements.md` (REQ-FR-xx). Visual reference: `design/translatecall.pen` frames «Setup — 1…4», read only through the pencil MCP (`execute` with the file's uri; the user's active canvas may be another project — don't touch it). The prototype uses Inter and Lucide as stand-ins; build with the system font and SF Symbols.

## 1. Approaches considered

| | Approach | Trade-off | Verdict |
|---|---|---|---|
| 1 | Dedicated service for everything; the rehearsal chains STT → translation → TTS for one sentence itself | Simple, isolated, easy to test — but the rehearsal does not run the code a call runs, so it can pass and the call still fail | Rejected |
| **2** | **Basic checks in a dedicated service; the rehearsal runs the real `AudioCoordinator` session outgoing-only in a rehearsal mode** | Tests exactly the call path; costs a rehearsal mode so the rest of the app stays quiet | **Chosen (user, 2026-11-16)** |
| 3 | Everything through the real session, the fixed phrase included | Least new code — but the basic check would need the language pack, which defeats option C | Rejected |

A second-opinion review (2026-11-16) agreed with 2 and found the gaps now covered by F-3, REQ-FR-21, 42, 50–57 and §6.

## 2. Prototype → SwiftUI map

| Prototype frame (light / dark) | SwiftUI | REQ |
|---|---|---|
| Setup — 1 (`btiTo` / `WBniD`) | `PermissionsStepView` | 10–13 |
| Setup — 2 (`on56i` / `zr8r0`) | `AudioDriverStepView` | 20–21 |
| Setup — 3 (`dTLjH` / `sXDI2`) | `CallAppMicStepView` | 30–33 |
| Setup — 4 (`YDVmk` / `lHIVU`) | `TestStepView` (+ `RehearsalBox`) | 40–58 |
| window chrome + sidebar | `SetupAssistantView` in `Window(id: "setup")` | 01–05 |

Copy follows the frames; where a requirement adds a state the frame lacks (failures, "not ready" rehearsal box), match the frame's type scale and colours. Implementers screenshot the frame (light and dark) before writing each view and compare it with a render of the view before review (offscreen `NSHostingView` from a temporary, uncommitted test).

## 3. File layout

Synchronized folders: new files need no `project.pbxproj` edit.

```
TranslateCall/
  Core/Setup/       SetupManager.swift (slimmed, + step persistence), SetupStep.swift,
                    BlackHoleDevice.swift (exact 2ch lookup), PermissionRequester.swift,
                    LevelMeter.swift (pure dBFS maths), BlackHoleListener.swift,
                    SetupChecks.swift (mic + route checks), Rehearsal.swift (rehearsal driver)
  Features/Setup/   SetupAssistantView.swift, SetupSidebar.swift, PermissionsStepView.swift,
                    AudioDriverStepView.swift, CallAppMicStepView.swift, TestStepView.swift,
                    RehearsalBox.swift, LevelMeterView.swift, SetupWindowOpener.swift
```

Removed (REQ-FR-60): `SetupWizardView.swift`, `Step1…Step4_*View.swift`, `RouteTestService.swift`; the ScreenCaptureKit app list in `SetupManager` if nothing else uses it (the main window already uses `CallAppMonitor`).

## 4. Window and navigation (REQ-FR-01…05, 03)

- A `Window("Set up TranslateCall", id: "setup")` scene in `TranslateCallApp`, opened through a small `SetupWindowOpener` (same pattern as `MainWindowOpener`) from: launch when `!isSetupCompleted`, the audio-driver card, Settings › Advanced. `Window` (not `WindowGroup`) guarantees one instance.
- `SetupStep: Int, CaseIterable { permissions, audioDriver, callAppMic, test }`. `SetupManager` gains `currentStep` persisted in `tlk.setup.step`; `completeSetup()` clears it. Sidebar state per step is derived (permissions both granted; BlackHole 2ch present; step 3 marked done or "None"; step 4 any check passed) — derived, not stored, except step 3's "I've done it" (`tlk.setup.callAppMicConfirmed`).
- Closing the window (`onDisappear` of the scene's root) cancels the test step's tasks (§5, §6).

## 5. Basic checks (REQ-FR-40…43)

### 5.1 BlackHole 2ch lookup (REQ-FR-21)
`BlackHoleDevice.find() -> AudioDeviceID?` matches the device whose name is exactly "BlackHole 2ch" (case-insensitive) or whose UID is `BlackHole2ch_UID`; `anyOtherBlackHole() -> Bool` supports the "needs the 2-channel version" message. `SetupManager.isBlackHolePresent` and `AudioViewModel.startPipeline` switch to it. `AudioDevice.deviceID(forNameContaining:)` stays for other callers.

### 5.2 Listener
`BlackHoleListener` owns its own `AVAudioEngine` whose input unit is set to BlackHole 2ch with `CoreAudioDevices.setCurrentDevice` — the same technique as the integration tests, but **not** via `AudioManager`, whose input selection is persisted and which holds the microphone during the rehearsal. It publishes per-buffer peak dBFS through an `AsyncStream<Float>` and can record buffers into memory (REQ-FR-55). Needs microphone permission (macOS treats any input device as microphone); without it the check fails early with the step-1 link.

### 5.3 Detection logic
`LevelMeter` is pure and unit-tested: dBFS of a buffer; `SustainedLevelDetector(threshold:, minDuration:)` fed with `(level, duration)` pairs. `SetupChecks` (`@MainActor ObservableObject`) composes:
- **Mic check:** an `AVAudioEngine` input tap on the user's selected input (resolved like `AudioManager.chooseInput`, read-only) → meter values for `LevelMeterView`, pass at −40 dBFS / 300 ms. Runs while step 4 is visible and no rehearsal is running (the rehearsal needs the mic).
- **Route check:** listener on → 300 ms baseline (REQ-FR-42) → play the fixed phrase with `TTSPlaybackService(primary: AVSpeechUtteranceSynthesizer(), output: TTSOutput(deviceID:))` (today's `RouteTestService` code) → pass at −70 dBFS sustained 200 ms within 3 s of playback start → listener off.
Timeouts use an injected `Clock` so tests run with a test clock.

## 6. Rehearsal (REQ-FR-50…58)

### 6.1 Rehearsal mode in the coordinator
`AudioCoordinator.start` gains `rehearsal: Bool = false` (stored as `isRehearsal` for the session). In rehearsal mode:
- `captureTarget` is forced to nil (incoming `.disabled`, as today without a target);
- the transcript is snapshotted before `beginSessionUIState()` and restored in `endSessionUIState()`; the rehearsal's own entries are exposed to the wizard through a separate `rehearsalEntry` (latest outgoing transcript + translation) instead;
- pipeline errors are routed to `rehearsalError` instead of `errorAlert`;
- everything else (VAD, STT, translation, TTS to BlackHole, voice clone if on, clause split) runs unchanged — that is the point of F-2.

### 6.2 Keeping the app quiet (F-3, REQ-FR-56)
The observers key off `coordinator.isOutgoingActive`. Rather than touching each, `CallSessionModel.phase(...)` maps a rehearsal — from `start(rehearsal: true)` until `stop()` returns, so `isStarting` included — to a new `SessionPhase.rehearsing` (every exhaustive `switch` over `SessionPhase` handles it: `Readiness.derive`, menu bar icon, `routeAlert`, `TranscriptView.isSessionActive`, …); every observer that reacts to `.running` (status panel controller, main-window dismissal, menu bar state, `AppContainer`'s post-session preload) is checked against it — the builder lists them with a search for `isOutgoingActive` / `.running` readers and adds a test per observer that `.rehearsing` does not trigger it. Readiness maps `.rehearsing` to a disabled primary with "Setup test in progress" (main window and menu bar).

### 6.3 Driver
`Rehearsal` (`@MainActor ObservableObject`) runs the sequence:
1. Gate: the current session phase must be `.idle` (else REQ-FR-57b); `Readiness.derive(permissions:, blackHolePresent:, pair:, app: nil, phase: .idle, modelDownloading:)` must yield an enabled Start; plus `BlackHoleDevice.find() != nil` and microphone `.granted` (Readiness does not check these). Else show the reason (REQ-FR-50).
2. Edge consent (REQ-FR-51): read `AudioViewModel.needsEdgeConsentBeforeStart`; show the wizard's own alert; on accept call `ttsEngineSelector.grantEdgeTTSConsent()` and continue. Never touch `pendingStartAfterConsent` / `showEdgeTTSConsent` (they start a normal session from the main window).
3. Stop the mic check; start the listener (recording on); `coordinator.start(captureTarget: nil, blackHoleDeviceID: BlackHoleDevice.find(), rehearsal: true)`. "Preparing…" until `audioCapture.isCapturing`.
4. End rule (REQ-FR-53): track only the first outgoing entry. Done when it has a translation, the coordinator has no pending outgoing delivery for it (all clause-split parts handed to TTS — the builder exposes this from `AudioCoordinator+Delivery`) and `isOutgoingSpeaking` has stayed false for 1.5 s; the listener must have passed during its speech (REQ-FR-54). Timers start when `isCapturing` goes true: 15 s to a transcript, 30 s to completion; "Preparing…" capped at 90 s. All three run on the injected clock.
5. Always `coordinator.stop()`, listener off, mic check back on. Cancellation (leaving the step, closing the window, Finish) runs step 5.
6. On pass: "Play" plays the in-memory recording through an `AVAudioPlayerNode` on the default output (REQ-FR-55).

## 7. Steps 1–3

- **Permissions:** `PermissionRequester` wraps `AVCaptureDevice.requestAccess(for: .audio)`, `CGRequestScreenCaptureAccess()`, opening the Privacy panes (`x-apple.systempreferences:` URLs) and relaunch ("Reopen TranslateCall": `NSWorkspace.openApplication` of `Bundle.main.bundleURL` with `createsNewApplicationInstance`, then `NSApp.terminate`). States come from `PermissionState.current()`, refreshed on `NSApplication.didBecomeActiveNotification`.
- **Audio driver:** existing download URL from today's Step 1 view; state from §5.1.
- **Call app microphone:** the picker reuses `CallAppMonitor.rows` (as the main window's `CallAppSection`), with "None — translate only my voice"; per-app steps from `VideoCallApp`; "Open <app>" via `CallAppMonitor.open`.

## 8. Testing

- Unit: `LevelMeter` / `SustainedLevelDetector`; route-check and rehearsal state machines with fakes for listener, TTS and coordinator and a test clock (pass, baseline busy, timeout, no transcript, cancel mid-way always stops); `SetupStep` persistence; `BlackHoleDevice` matching on a fake device list; `CallSessionModel` maps rehearsal to `.rehearsing` and each observer ignores it; transcript snapshot/restore; errors routed to `rehearsalError`.
- Integration (BlackHole 2ch installed, else skipped like `Prerequisites.swift`): route check passes end to end; listener baseline sees silence.
- Manual checklist (in `tasks.md`): first run on a clean user (permissions + relaunch resume), BlackHole absent → present, rehearsal with pack installed and with pack missing, rehearsal while the voice clone is on, close window mid-rehearsal, Start disabled during rehearsal, light/dark vs. frames, VoiceOver pass.

## 9. Left to the builder

- Exact sidebar width, window size and min size (from the frames).
- Where the mic-check engine and the listener share code.
- The precise list of `.running` observers (§6.2) — found by search, each covered by a test.
- Wording of failure messages not given in the requirements, in the frames' tone.
