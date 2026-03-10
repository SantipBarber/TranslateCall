# F4.3 – Video Call Integration

**Milestone**: M4 – Full Pipeline Integration
**Feature**: F4.3 – Video Call Integration
**Status**: DRAFT – Pending Gate 1 Review
**Date**: 2026-03-10
**Depends on**: F4.1 (AudioCoordinator with `captureApp` param), F4.2 (HalfDuplexManager)

---

## 1. Context & Motivation

F4.1 and F4.2 deliver a complete bidirectional pipeline with echo prevention, but the app is not yet usable in a real video call. Three problems remain:

1. **No setup guidance**: The user must independently install BlackHole, configure their video call app, and understand the routing architecture — there is no in-app onboarding.
2. **No capture app selection**: `AudioCoordinator.start()` accepts `captureApp: SCRunningApplication?` but the UI always passes `nil`. The user cannot select which app's audio to capture for the incoming pipeline.
3. **No routing validation**: There is no way for the user to verify that TranslateCall is correctly routing audio through BlackHole before joining a call.

F4.3 closes all three gaps, making TranslateCall usable end-to-end by a first-time user.

---

## 2. Scope

**In scope for F4.3**:
- **BlackHole readiness check**: Detect BlackHole at app launch; surface install guidance if absent
- **Capture app selector**: UI picker to select which running application's audio to capture (incoming pipeline)
- **Setup wizard**: Guided 4-step first-launch flow (install check → video app config → capture app select → route test)
- **Route test**: Play a brief TTS phrase routed to BlackHole; confirm the device receives audio
- **Per-app instruction cards**: Static step-by-step guides for Zoom, Teams, Meet, and Discord
- **Session start UX**: "Start" button passes the selected capture app to `AudioCoordinator.start()`

**Out of scope for F4.3**:
- Automated configuration of third-party apps (requires Accessibility permissions)
- FaceTime support (no virtual device support)
- Audio MIDI Setup automation (complex, out of scope for MVP)
- Full diagnostics dashboard (M5)
- Crash diagnostics, log export (M5)

---

## 3. Functional Requirements

### 3.1 BlackHole Readiness Check

**FR-4.3.1** WHEN the app launches THEN the system SHALL check whether a CoreAudio device with "BlackHole" in its name is present using `AudioDevice.deviceID(forNameContaining:)`.

**FR-4.3.2** IF BlackHole is not detected THEN the app SHALL display a non-blocking banner or badge in the main window indicating BlackHole is not installed.

**FR-4.3.3** IF BlackHole is not detected AND the user attempts to start a session THEN the session SHALL start in outgoing-only mode (incoming pipeline disabled) and the user SHALL be informed that incoming translation requires BlackHole.

**FR-4.3.4** The blackHole readiness state SHALL be re-evaluated WHEN the user re-focuses the app window (in case they installed BlackHole while TranslateCall was in the background).

### 3.2 Capture App Selector

**FR-4.3.5** WHEN the user is about to start a session THEN the app SHALL offer a picker to select which running application's audio to capture for the incoming pipeline.

**FR-4.3.6** The capture app list SHALL be populated by calling `SCShareableContent.current()` and filtering `applications` to known video call apps by bundle ID: `us.zoom.xos`, `com.microsoft.teams2`, `com.google.meet`, `com.discord`, `com.apple.FaceTime`.

**FR-4.3.7** IF no known video call app is running THEN the picker SHALL display all running applications with audio (non-empty `displayName`) as a fallback, plus a "None (outgoing only)" option.

**FR-4.3.8** The selected capture app SHALL be persisted in `UserDefaults` (by bundle identifier) and restored on next launch.

**FR-4.3.9** WHEN the user taps "Start" THEN `AudioCoordinator.start(captureApp:blackHoleDeviceID:)` SHALL be called with the selected `SCRunningApplication` (or `nil` if "None" is selected).

### 3.3 Setup Wizard

**FR-4.3.10** WHEN the app launches for the first time (no `UserDefaults` key `tlk.setupCompleted == true`) THEN the setup wizard SHALL be presented automatically as a sheet.

**FR-4.3.11** The setup wizard SHALL have four steps presented sequentially:
- **Step 1 – BlackHole Check**: Detect presence, show install command if absent (`brew install blackhole-2ch`), offer "Refresh" button
- **Step 2 – Video App Setup**: Show per-app instruction card for the selected/detected video call app (see §3.4)
- **Step 3 – Capture App Select**: Allow the user to select which running app to capture (same as FR-4.3.6)
- **Step 4 – Route Test**: Play a test tone through the pipeline and confirm setup is complete

**FR-4.3.12** The user SHALL be able to navigate back to any previous step.

**FR-4.3.13** WHEN the user completes Step 4 THEN `UserDefaults` key `tlk.setupCompleted` SHALL be set to `true` and the wizard SHALL dismiss.

**FR-4.3.14** The wizard SHALL be re-openable at any time via a "Setup…" menu item or button in the main window.

**FR-4.3.15** The user SHALL be able to dismiss the wizard at any step; `tlk.setupCompleted` SHALL only be set on explicit completion of Step 4.

### 3.4 Per-App Instruction Cards

**FR-4.3.16** The wizard Step 2 SHALL show a static instruction card for the detected or user-selected video call app. Each card contains:
- App name + icon (SF Symbol or image asset)
- Numbered steps (text only, no screenshots for MVP)
- Estimated time

**FR-4.3.17** Instruction cards SHALL be provided for: **Zoom**, **Microsoft Teams**, **Google Meet** (browser), **Discord**.

**FR-4.3.18** Zoom instructions SHALL cover: Settings → Audio → Microphone → select "BlackHole 2ch".

**FR-4.3.19** Teams instructions SHALL cover: Settings → Devices → Microphone → select "BlackHole 2ch".

**FR-4.3.20** Meet/Discord instructions SHALL cover equivalent microphone selection steps.

**FR-4.3.21** IF no known app is detected THEN a generic card SHALL explain the principle: "Select BlackHole 2ch as the microphone in your video call app's audio settings."

### 3.5 Route Test

**FR-4.3.22** The route test SHALL play a brief TTS phrase (e.g., "Testing audio routing. TranslateCall is ready.") via `AVSpeechService` routed to BlackHole.

**FR-4.3.23** IF BlackHole is present THEN the test SHALL succeed immediately (the test verifies routing by device ID, not audio feedback loop).

**FR-4.3.24** WHEN the test plays THEN the UI SHALL show an animated waveform or progress indicator for the duration of the phrase (~2 seconds).

**FR-4.3.25** AFTER the test completes THEN the UI SHALL show a success checkmark and prompt the user to confirm they heard/saw audio activity in their video call app.

### 3.6 Main Window Integration

**FR-4.3.26** The main window SHALL display a "BlackHole not detected" warning badge below the device pickers when `isBlackHolePresent == false`.

**FR-4.3.27** The main window SHALL include a capture app picker (compact, single row) above the Start button showing the currently selected capture app.

**FR-4.3.28** A "Setup…" link/button SHALL appear in the main window that re-opens the wizard.

---

## 4. Non-Functional Requirements

**NFR-4.3.1** `SCShareableContent.current()` SHALL be called at most once per session start attempt, NOT on every UI update, to avoid repeated permission prompts.

**NFR-4.3.2** The setup wizard SHALL load within 1 second of being triggered (no network calls; BlackHole check is synchronous CoreAudio query).

**NFR-4.3.3** The route test tone SHALL use the existing `AVSpeechService` — no new audio subsystem is introduced.

**NFR-4.3.4** All wizard state (current step, selected app, completion status) SHALL survive app restart via `UserDefaults`.

---

## 5. Constraints

**C-4.3.1** `SCShareableContent.current()` requires `com.apple.security.screen-capture` entitlement (already present from F4.1) and user permission. If permission is denied, the capture app selector SHALL show an empty list with a "Grant Permission" button.

**C-4.3.2** `SCRunningApplication` does not carry a bundle identifier in all cases; `bundleIdentifier` may be empty. The filter SHALL fall back to `displayName` matching ("Zoom", "Teams", "Meet", "Discord") when `bundleIdentifier` is nil/empty.

**C-4.3.3** The route test cannot verify audio receipt by the video call app without AEC or loopback capture. The test is declarative (plays audio to BlackHole device) — it verifies the device exists and audio was sent, not that the remote participant will hear it.

**C-4.3.4** FaceTime does not support virtual audio devices (system restriction). The wizard MUST NOT present FaceTime as a supported app.

---

## 6. Acceptance Criteria

| ID | Criterion | Test Method |
|----|-----------|-------------|
| AC-4.3.1 | Warning badge shown when BlackHole not detected | Unit: mock `isBlackHolePresent = false`, verify badge visible |
| AC-4.3.2 | Wizard appears on first launch | Unit: clear `tlk.setupCompleted`, launch app, verify wizard presented |
| AC-4.3.3 | Wizard does NOT appear if already completed | Unit: set `tlk.setupCompleted = true`, verify no wizard |
| AC-4.3.4 | Step 1 shows install command when BlackHole absent | UI test / manual |
| AC-4.3.5 | Step 1 "Refresh" re-checks device presence | Unit: inject device list change, tap refresh, verify state updates |
| AC-4.3.6 | Capture app list shows running Zoom/Teams/Meet/Discord | Integration: run with Zoom open, verify it appears in picker |
| AC-4.3.7 | Selected capture app persisted and restored | Unit: set app, restart, verify same app selected |
| AC-4.3.8 | Start button passes selected capture app to coordinator | Unit: mock coordinator, verify `start(captureApp:)` called with correct app |
| AC-4.3.9 | Route test plays audio without crash | Unit: `AVSpeechService` with BlackHole device ID, no throw |
| AC-4.3.10 | Wizard completion sets `tlk.setupCompleted = true` | Unit: complete wizard, read UserDefaults |

---

## 7. Open Questions

| # | Question | Owner | Status |
|---|----------|-------|--------|
| OQ-1 | Should the wizard be a sheet or a separate window? For a menu bar app (future), a separate window is better; for the current window app, a sheet is simpler. | UX | **Tentative: sheet** |
| OQ-2 | Should the route test require the user to run their video call app first (so they can confirm they heard audio), or is a simple "test sent" confirmation sufficient for MVP? | UX | **Tentative: simple "test sent" is sufficient for MVP** |
| OQ-3 | Should "None (outgoing only)" be the default capture app selection until the wizard is completed? | UX | **Yes — safe default; incoming requires explicit opt-in** |
| OQ-4 | How to handle SCShareableContent permission denial gracefully in the wizard? | Engineering | **Show "Grant Permission" button opening System Settings** |

---

## 8. Dependencies

| Feature | Dependency Type | Notes |
|---------|----------------|-------|
| F4.1 AudioCoordinator | Extend | `captureApp:` param already exists, now must be wired from UI |
| F4.2 HalfDuplexManager | Runtime | Active during sessions triggered from wizard |
| F3.2 LanguagePairManager | Reuse | Wizard can suggest downloading language pair if not installed |
| M5 Polish | Downstream | Full diagnostics, crash reporting, log export deferred |

---

*End of F4.3 Requirements — Gate 1 Review Pending*
