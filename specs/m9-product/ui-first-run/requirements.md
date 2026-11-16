# M9 UI first-run setup assistant — Requirements

> Status: DRAFT (2026-11-16) — brainstorm decisions F-1…F-6 and the second-opinion review folded in; waiting for the builder check and the user's approval.
> Inputs: `specs/m9-product/ui-redesign/roadmap.md` (feature 3), `specs/m9-product/ui-redesign/design-brief.md` (sections 5 and "What the app picker drives"), `specs/m9-product/ui-core/` and `ui-settings/` (features 1–2, merged), `design/translatecall.pen` frames «Setup — 1…4» (pencil MCP only).

## Overview

Audio routing needs BlackHole 2ch and the call app's microphone set to BlackHole, so the first-run setup cannot disappear; it can only get simpler and more trustworthy. Today it is a 480×380 sheet with four steps whose test only plays a phrase to BlackHole and never checks that it arrived.

This feature replaces it with the prototype's assistant: a window with a sidebar of four steps (Permissions, Audio driver, Call app microphone, Test) whose last step really checks the outgoing route and, when the language is ready, rehearses a real translation.

**Why:** a user who finishes setup should trust that the other side will hear the translation before their first call. A test that cannot fail is worse than none.

## Decisions taken (brainstorm 2026-11-15/16)

| ID | Decision |
|----|----------|
| F-1 | **Step 4 is option C.** Basic checks always (microphone level, fixed phrase verified at BlackHole's input); a full rehearsal only when the current pair is ready. |
| F-2 | **Approach 2.** The checks live in a small dedicated service. The rehearsal runs the real `AudioCoordinator` session, outgoing only (no capture target → incoming `.disabled`), so it exercises exactly the code a call uses. Rejected: a one-shot STT→translate→TTS chain only for the wizard (does not test the call path); everything through the real session (the basic check would need the language pack). |
| F-3 | **The rehearsal is invisible to the rest of the app.** No status panel, no main-window dismissal, no "translating" menu bar state, no transcript entry left behind, no error modal in the main window; the wizard shows its own result and errors. |
| F-4 | **The user hears the result.** After a successful rehearsal, "Play" plays what the call app received on the user's output device. |
| F-5 | **Step 3 is not verified.** "I've done it" is trusted. Detecting that the call app has BlackHole open as input (CoreAudio process objects, macOS 14+) goes to the backlog as a spike (UI-S1). |
| F-7 | *(Claude's call, builder check)* **Rehearsal unit and timers:** the first sentence fully delivered (all clause-split parts); timers start once capture runs; "Preparing…" capped at 90 s (REQ-FR-53). |
| F-8 | *(Claude's call, builder check)* **During a real call** step 4 is unavailable; steps 1–3 work (REQ-FR-57b). |
| F-9 | *(Claude's call, builder check)* **A new `SessionPhase.rehearsing`**, starting stretch included; Start disabled with "Setup test in progress" (REQ-FR-56). |
| F-6 | **Failing a check never blocks finishing.** The user can finish setup with failed or skipped checks; the main window's readiness cards keep pointing at what is missing. |

## Non-goals

- Verifying incoming audio (the call app's sound): "Checked in your first call."
- Verifying the call app's microphone setting (F-5).
- Downloading language packs or models inside the assistant (the main window owns downloads).
- Installing BlackHole for the user (we link to its download page).

## Anti-goals (a failure even if it works)

- A check that reports success when the call app would hear nothing (e.g. BlackHole 16ch or an aggregate device instead of BlackHole 2ch).
- A rehearsal that looks like a call: status panel, main window closing, transcript polluted.
- An assistant that traps the user: permissions that need a relaunch must not send them back to step 1.

## Functional Requirements

### FR-FR.1 — Window and navigation

**REQ-FR-01**: The assistant SHALL be its own window with a sidebar listing the four steps (prototype frames `btiTo`/`on56i`/`dTLjH`/`YDVmk` light, `WBniD`/`zr8r0`/`sXDI2`/`lHIVU` dark), replacing `SetupWizardView`'s sheet. Each sidebar row shows the step's state: not done, done (checkmark), needs attention.

**REQ-FR-02**: It SHALL open on launch while setup is not completed, from the main window's audio-driver card ("Set up"), and from Settings › Advanced › "Run setup again…". Opening it while it is open brings it to the front.

**REQ-FR-03**: The current step SHALL persist (`tlk.setup.step`), so a relaunch requested by macOS for a permission resumes at that step. Completing setup clears it.

**REQ-FR-04**: The user SHALL be able to move to any step from the sidebar and with Back/Continue. "Finish" on step 4 calls `completeSetup()` and closes the window, whatever the checks' results (F-6).

**REQ-FR-05**: Closing the window SHALL stop any running check or rehearsal and leave setup not completed unless Finish was pressed.

### FR-FR.2 — Step 1, Permissions

**REQ-FR-10**: Step 1 SHALL show Microphone and "Screen & System Audio Recording", each with its state and an "Allow…" button, and the note that macOS may ask to reopen the app.

**REQ-FR-11**: "Allow…" for the microphone SHALL request access itself (`AVCaptureDevice.requestAccess(for: .audio)`); today it is only requested inside `startCapture`. When denied, the button opens the Privacy pane of System Settings.

**REQ-FR-12**: "Allow…" for screen recording SHALL call `CGRequestScreenCaptureAccess()`; when it stays denied, the button opens the Screen Recording pane. Because the grant is only visible after relaunch, the step SHALL say so and offer "Reopen TranslateCall" (relaunch, resuming at this step via REQ-FR-03).

**REQ-FR-13**: Permission states SHALL refresh when the app becomes active.

### FR-FR.3 — Step 2, Audio driver

**REQ-FR-20**: Step 2 SHALL show the diagram "Your voice → TranslateCall → BlackHole → call app", the driver's state, "Download BlackHole 2ch" (opens the existing download URL) and "Check again". The state also refreshes when the app becomes active.

**REQ-FR-21**: The driver check SHALL look for a device named exactly "BlackHole 2ch" (or its UID), never the first name containing "BlackHole". The same lookup SHALL be used by the session (`AudioViewModel`'s BlackHole resolution) and by step 4. A BlackHole with another channel count present but no 2ch SHALL read "BlackHole 2ch not found — TranslateCall needs the 2-channel version".

### FR-FR.4 — Step 3, Call app microphone

**REQ-FR-30**: Step 3 SHALL list call apps from `CallAppMonitor` (NSWorkspace; no screen-recording permission needed), preselecting the persisted choice or the first running known app.

**REQ-FR-31**: Picking an app SHALL persist it as the call app (`SetupManager.selectCaptureApp(bundleID:)`), which also sets incoming capture (design brief, "What the app picker drives").

**REQ-FR-32**: The step SHALL show the app's three steps to set BlackHole 2ch as its microphone (per-app copy from `VideoCallApp`, generic copy for others), "Open <app>" and "I've done it". "I've done it" marks the step done; it is not verified (F-5).

**REQ-FR-33**: "None — translate only my voice" SHALL remain available; with it, the step reads that the other side will not be translated and step 3 counts as done.

### FR-FR.5 — Step 4, Test: basic checks (always)

**REQ-FR-40**: **Microphone check.** While step 4 is visible, a live level meter SHALL show the selected input device's level. The check passes when speech-level audio (above −40 dBFS for at least 300 ms) is seen; the text reads "Say something" until then, then "We can hear you". Needs microphone permission; without it the check shows "Microphone access is off" with a link to step 1.

**REQ-FR-41**: **Route check.** "Test" SHALL play a fixed phrase with the system voice to BlackHole 2ch while a listener captures BlackHole 2ch's input. It passes when the listener sees audio above −70 dBFS within 3 s of playback start, sustained for at least 200 ms. Otherwise it fails with "BlackHole isn't receiving audio" and "Try again".

**REQ-FR-42**: Before the route check, the listener SHALL measure BlackHole's input for 300 ms; if something else is already playing into it (above −70 dBFS), the check SHALL say "Another app is sending audio to BlackHole — close it and try again" instead of passing.

**REQ-FR-43**: Each check SHALL show idle / running / passed / failed with a specific message; a missing prerequisite (no BlackHole 2ch, no microphone permission) SHALL say which step fixes it and link to it.

### FR-FR.6 — Step 4, Test: full rehearsal (when ready)

**REQ-FR-50**: The rehearsal box SHALL be enabled only when `Readiness.derive` for the current state (with no call app) would allow Start (microphone not denied, the pair installed and supported, no model download in flight) **and**, checked separately because `Readiness` does not gate on it, BlackHole 2ch is present and the microphone is granted. When not, it shows why in one line ("Available once English ↔ Spanish is downloaded", "Waiting for the download to finish", …). It never offers a download.

**REQ-FR-51**: If the outgoing voice needs Edge consent that has not been given, "Rehearse" SHALL ask for it first, in the wizard window, with the same text as Start's alert (`needsEdgeConsentBeforeStart`). Accepting grants consent and starts the rehearsal; it never starts a normal session (the wizard has its own consent path, not `pendingStartAfterConsent`).

**REQ-FR-52**: "Rehearse" SHALL start the real session outgoing only, in rehearsal mode (F-3), show "Preparing…" until capture runs, then "Say a short sentence in <my language>".

**REQ-FR-53**: The rehearsal's unit is **the first outgoing transcript entry, fully delivered**: it has a translation and nothing remains to be spoken for it (all clause-split parts spoken), confirmed by 1.5 s with `isOutgoingSpeaking` false and no pending outgoing delivery. Later utterances are ignored (the session stops right after). Timers start when capture is running ("Say a short sentence…" shown), not at "Rehearse": fail after 15 s with no transcript ("We didn't hear you — try again, a bit louder") or 30 s with no complete delivery heard at BlackHole. "Preparing…" (model loading) has its own cap of 90 s ("Preparing is taking too long — try again"). The session is always stopped at the end.

**REQ-FR-54**: While the translated voice plays, the listener SHALL confirm audio at BlackHole 2ch (same threshold as REQ-FR-41). The result shows "You said: <transcript>" and "<app> receives: <translation>" with a check, or the specific failure.

**REQ-FR-55**: During the rehearsal the listener SHALL record what reaches BlackHole; after a pass, "Play" plays that recording on the default output device (F-4). The recording is kept in memory only and dropped when the step closes.

**REQ-FR-56**: In rehearsal mode the rest of the app SHALL not react as to a call (F-3): `CallSessionModel.phase` is `.rehearsing` from "Rehearse" until the session has stopped (the starting stretch included), never `.starting`/`.running`; no status panel; the main window is not dismissed; the menu bar does not show "translating"; the rehearsal leaves no transcript entries; pipeline errors go to the wizard (shown as the rehearsal's failure), not to the main window's alert; the post-session preloader refresh does not run; the transcript of the previous call is still there afterwards. While a rehearsal runs (at most ~2 min with the caps of REQ-FR-53; usually seconds), Start in the main window and the menu bar SHALL be disabled with the hint "Setup test in progress" (design §6).

**REQ-FR-57**: Leaving step 4, closing the window or pressing Finish SHALL stop a running rehearsal and checks and release BlackHole and the microphone.

**REQ-FR-57b**: While a real call runs (phase `.starting`/`.running`/`.launching`), step 4 SHALL show "Available when no call is running" and run no check, no mic meter and no rehearsal (the test phrase would reach the other side). Steps 1–3 stay usable. If a call starts while step 4 is open, its checks stop.

**REQ-FR-58**: Incoming audio SHALL be shown as "Audio from <app> — checked in your first call" (no check).

### FR-FR.7 — Cleanup

**REQ-FR-60**: `SetupWizardView`, its four step views and `RouteTestService` SHALL be removed. `SetupManager.loadCaptureApps` / `refreshCaptureApps` / `requestScreenCapturePermission` and the `SCRunningApplication` state are removed if no other caller remains.

**REQ-FR-61**: The backlog SHALL gain UI-S1 (spike: detect whether the call app has BlackHole 2ch open as input).

## Non-functional

**NF-FR-01**: All user-facing strings localizable; VoiceOver labels on every check state and the level meter.
**NF-FR-02**: Light and dark mode as in the prototype; system font and SF Symbols instead of the prototype's Inter/Lucide.
**NF-FR-03**: The checks' detection logic (thresholds, timeouts, rehearsal end rule) SHALL be unit-tested with injected buffers and a test clock; the BlackHole round trip SHALL have an integration test that runs where BlackHole 2ch is installed (skipped otherwise, as the existing integration tests do).
**NF-FR-04**: No new dependency.
