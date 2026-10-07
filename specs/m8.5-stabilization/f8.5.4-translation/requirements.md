# F8.5.4 — Translation — Requirements

> Status: APPROVED (2026-10-07) — with the planning decisions D-8, D-9 and P2–P4/P6 folded in
> Backlog: `specs/m8.5-stabilization/backlog.md` (items A8, T4 translation part, T5, A10 remainder in Core/STT + Core/Translation). T2 stays out (own task after F8.5.4).

## Overview

Translation is the pipeline's only unguarded failure point: a translation that never returns stalls its direction for the rest of the call, and a failed one raises a modal alert and loses the sentence. It is also slow on the first sentence of a pair (~0.8–1.1 s while the model loads). F8.5.4 keeps one Apple `TranslationSession` alive per direction, warms it up at Start, bounds every request with a timeout and one retry, refuses to start a call whose language packs are not downloaded, makes translation independent of the main window, and removes the last unchecked concurrency escapes in STT and Translation. The steady per-sentence cost (~250–450 ms) is model inference and stays (D-8).

## Motivation (code reading 2026-10-07)

| ID | Defect | Effect for the user |
|----|--------|---------------------|
| T4 | `TranslationBridgeModel.enqueue` calls `configuration.invalidate()` for every sentence, so SwiftUI re-runs `.translationTask` and builds a new `TranslationSession` each time (`TranslationBridge.swift:38-45`). | 300–960 ms per sentence in the F8.5.0 tier. Re-measured in planning (D-8): the high values are the first sentence of a pair (model load); a fresh session per sentence costs only ~10–20 ms more than a kept one. |
| — | The call-time bridges cannot show the download sheet; starting a call with a pair that is not downloaded makes every sentence fail (planning P9). | Silent failure for the whole call. |
| A8 | No timeout. If the session never answers, or `.translationTask` never fires (no view in a window), the continuation is never resumed and the direction's `for await` loop over STT results blocks for the rest of the call. | One direction silently stops translating. |
| A8 | The bridges live inside the `WindowGroup` (`TranslateCallApp.swift:13-14`). Closing the main window (the app stays alive in the menu bar) removes the views. | Translation stops when the window is closed. |
| A8 | Single pending slot: a new operation fails the pending one with `bridgeUnavailable`. `downloadLanguages()` uses the outgoing bridge, so "Download" during a call cancels a sentence. | A sentence is lost and an alert says "Restart the app". |
| — | Any translation error raises a modal alert (`errorAlert`) and the sentence is dropped. | Breaks F8.5.3 goal "no sentence lost silently"; modal alerts interrupt a call. |
| T5 | `TranslationService.supports` defaults to `true` (`TranslationService.swift:51`); `AppleTranslationService` does not override it, while `TranslationEngineSelector.supports` already asks `LanguageAvailability`. | Callers through the protocol get a wrong answer. |
| A10 | `nonisolated(unsafe)` on `AppleTranslationService.model` and on `locale` in `AppleSpeechService`, `WhisperSpeechService`, `ParakeetSpeechService`. | Unchecked data races; opengrep/strict concurrency cannot vouch for them. |

## Decisions taken (brainstorming 2026-10-07)

| ID | Decision |
|----|----------|
| D-1 | **Failure of one sentence:** retry once on a rebuilt session; if it fails again, skip the sentence and show a non-modal notice in the existing notice line. Modal alerts remain only for configuration errors (unsupported pair, models not installed). |
| D-2 | **Bridges live in a dedicated off-screen window** (`NSWindow` + `NSHostingView`) created and retained by `AppContainer` for the app's lifetime — the pattern already used by `hostTranslationBridge()` in the integration tests. The main window is UI only. |
| D-3 | **Downloads are separate from call-time translation.** `prepareTranslation()` shows a system sheet anchored to its view, so it runs from a `.translationTask` on the visible `LanguagePairView`, never on the hidden bridges. |
| D-4 | **Persistent session per direction (approach 1).** The `.translationTask` closure stays alive and serves a FIFO request queue; the configuration changes only on language-pair change, session warm-up at call start, or rebuild after a failure. |
| D-5 | **Per-request timeout 5 s** (injectable). Today's slowest observed call is ~1 s. |
| D-6 | **Measure first.** The first implementation task is an integration test that measures warm-session vs per-call-session latency. If the warm session does not beat the per-call one by a clear margin, work stops and the user decides. |
| D-7 | macOS 26 `TranslationSession(installedSource:target:)` (no view) is **out of scope** (YAGNI): measured at 258 ms median, no faster than the bridge (D-8). Deployment target stays macOS 15.0. |
| D-8 | **Measurement result (Task 1 run during planning, Mac16,10, ES→EN, 10 short sentences):** session per sentence median 266–282 ms, kept session 256–262 ms, after 3–30 s pauses both ~300–460 ms; one word 62 ms. The cost is model inference, not session set-up, so NFR ≤ 150 ms is not reachable with Apple Translation. Opening a session alone does not load the model: the first sentence of a pair costs ~0.8–1.1 s cold and ~170–440 ms after a warm-up that translates a one-word probe. **Decision (P1 = a):** build as designed. The value of F8.5.4 is robustness (A8) and the warm-up at Start; NFR-TR-01 is relaxed accordingly. |
| D-9 | **Pack check at Start (planning P9, in scope):** a call does not start unless both directions' packs are installed; the user is told to download first. |

## Functional Requirements

### FR-8.5.4.1 — Persistent session

**REQ-TR-01**: Each direction SHALL have one `TranslationBridgeModel` whose `.translationTask` closure, once fired, SHALL serve translation requests from a FIFO queue until the task is cancelled, without changing or invalidating the configuration between requests.

**REQ-TR-02**: The configuration SHALL be replaced only when (a) the language pair of that direction changes, (b) a warm-up is requested for a pair with no live session, or (c) a rebuild is needed after a failed or timed-out request.

**REQ-TR-03**: Requests SHALL be answered in the order they were submitted. A request pending or in flight when the session is cancelled (pair change, rebuild) SHALL be served by the next session, not failed.

**REQ-TR-04**: A request whose pair differs from the live session's pair SHALL trigger the pair change (REQ-TR-02a) and be served by the new session.

**REQ-TR-05**: `AudioCoordinator.start` SHALL request a warm-up of both directions for the current pair, so the first sentence of a call does not pay the model start-up cost. A warm-up opens the session and translates a short probe (`"OK"`, result discarded), because opening a session alone does not load the model (D-8). It SHALL NOT delay the start of capture, and SHALL do nothing while requests are queued.

**REQ-TR-06**: Before anything else, `AudioCoordinator.start` SHALL check that the pack of each direction's pair (source → target and target → source) is `.installed` per `LanguageAvailability`. If either is not, the session SHALL NOT start (no capture, no warm-up) and a modal alert SHALL say to download the languages first ("Languages Not Downloaded"; "Download" stays available in the main window's language row). The check SHALL be injected into the coordinator so unit tests never call the real `LanguageAvailability`.

### FR-8.5.4.2 — Timeout and retry

**REQ-TR-10**: The request at the head of the queue (the one being served) SHALL be bounded by the timeout (default 5 s, injectable clock and duration), including when `.translationTask` never fires; a request therefore completes (value or error) within 2 × timeout of reaching the head. Requests are served one at a time, and each direction submits one sentence at a time, so the queue is normally one deep. (A per-request timer from submission would time out a waiting request while the head is being retried — planning P2.)

**REQ-TR-11**: On timeout or session error, the bridge SHALL rebuild the session and retry the request once. If the retry also fails, the request SHALL throw `TranslationError.timedOut` or `TranslationError.sessionError`, and the bridge SHALL rebuild the session again (planning P3).

**REQ-TR-12**: A failed request SHALL NOT affect later requests: the next request is served by the rebuilt session.

**REQ-TR-13**: Cancelling the caller's task SHALL remove its request from the queue — also when it is in flight; the session's late answer is discarded — and throw `CancellationError`, without affecting other requests (planning P4).

### FR-8.5.4.3 — Error reporting in the pipeline

**REQ-TR-20**: When translating one sentence fails with `timedOut` or `sessionError`, the coordinator SHALL skip that sentence, keep processing the next ones, and show a non-modal notice in the existing notice line (e.g. "A sentence could not be translated"), naming the direction.

**REQ-TR-21**: `unsupportedPair` and `modelNotLoaded` SHALL still raise the modal alert, at most once per call session per error kind.

**REQ-TR-22**: `TranslationError.bridgeUnavailable` SHALL be removed: the service holds its bridge model strongly, so the case can no longer occur (a missing view is reported as `timedOut`).

### FR-8.5.4.4 — Hosting independent of the main window

**REQ-TR-30**: Both call-time bridges SHALL be hosted in an off-screen, non-activating window owned by `AppContainer`, created at app launch and kept for the app's lifetime. They SHALL be removed from the `WindowGroup`.

**REQ-TR-31**: Translation SHALL keep working with the main window closed (menu-bar-only operation).

### FR-8.5.4.5 — Language download

**REQ-TR-40**: "Download" in `LanguagePairView` SHALL run `prepareTranslation()` from a `.translationTask` attached to the visible view, so the system download sheet appears in the main window. It SHALL NOT use the call-time bridges. The view hands its session to `AudioViewModel.downloadLanguages(using:)`, which takes any `TranslationSessioning` (planning P6), so the flow is unit-testable.

**REQ-TR-41**: After the download task completes (success or error), `LanguagePairManager.checkAvailability()` SHALL run; an error SHALL be shown as a modal alert ("Download Failed"); a cancellation (sheet dismissed, view gone) SHALL be silent.

**REQ-TR-42**: `TranslationService.prepare` SHALL be removed from the protocol (its only caller moves to REQ-TR-40).

### FR-8.5.4.6 — Supported pairs (T5)

**REQ-TR-50**: The default `supports` implementation on `TranslationService` SHALL be removed. `AppleTranslationService.supports` SHALL return `true` only for `LanguageAvailability` status `.installed` or `.supported`.

**REQ-TR-51**: `TranslationEngineSelector.supports` SHALL delegate to the service implementation instead of duplicating the check.

### FR-8.5.4.7 — Concurrency hygiene (A10 remainder)

**REQ-TR-60**: No `nonisolated(unsafe)` SHALL remain in `Core/STT` or `Core/Translation`. `locale` in the three STT services SHALL be protected by a lock (`Mutex`) or isolated state; `AppleTranslationService` SHALL hold its bridge without an unchecked escape.

**REQ-TR-61**: An opengrep rule (`no-nonisolated-unsafe-stt-translation`, ERROR, in its own `.opengrep/rules/swift-isolation.{yml,swift}`) SHALL fail the scan on `nonisolated(unsafe)` under `Core/STT` and `Core/Translation`.

## Non-Functional Requirements

**NFR-TR-01 (latency, relaxed by D-8)**: On the production path (`AppleTranslationService` → bridge → `TranslationHostWindow`) with a warm session, the median translation time of 10 short sentences (≤ 15 words, installed pair) SHALL be recorded in `build/reports/latency.json` and SHALL NOT exceed 400 ms (measured 246–264 ms). The first sentence after a warm-up SHALL take ≤ 600 ms (measured 169–440 ms; ~0.8–1.1 s without the probe). The session-per-sentence and kept-session baselines of D-8 stay recorded by the Task 1 probe.

**NFR-TR-02 (no hangs)**: No test or code path SHALL leave a `CheckedContinuation` unresumed; unit tests use injected clocks, never real sleeps.

**NFR-TR-03**: Unit tests SHALL NOT need a real `TranslationSession`: the bridge talks to the session through a small protocol that tests fake.

## Out of Scope

- macOS 26 `TranslationSession(installedSource:target:)` (D-7).
- Other translation engines (Opus-MT, LibreTranslate).
- T2 Whisper `small` / threshold for Ukrainian (own task after F8.5.4).
- Any VAD/STT/TTS latency work.

## Manual checks (user)

- **M1** Normal call ES↔EN: translations appear and are spoken; perceived delay is shorter than before.
- **M2** Close the main window mid-call: translation continues (menu bar); reopen the window, state is consistent. Then click the Dock icon: the main window comes back; closing the last window does not quit the app; the menu-bar 'show window' action raises the main window, not the hidden translation host.
- **M3** Change the language pair between calls: next call translates in the new pair.
- **M4** Press "Download" for an uninstalled pair: the system sheet appears in the main window; status updates afterwards.
- **M5** Right after M4, Start a session in that pair: the first sentence is translated (no "Couldn't translate…" notice). (Replaces "Download during a call": the language row is disabled during a session — planning P7.)
- **M6** Pick a pair that is not downloaded and press Start: the alert "Languages Not Downloaded" appears and no session starts (REQ-TR-06).
