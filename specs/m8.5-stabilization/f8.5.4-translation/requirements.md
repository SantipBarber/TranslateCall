# F8.5.4 — Translation — Requirements

> Status: DRAFT — pending user review (2026-10-07)
> Backlog: `specs/m8.5-stabilization/backlog.md` (items A8, T4 translation part, T5, A10 remainder in Core/STT + Core/Translation). T2 stays out (own task after F8.5.4).

## Overview

Translation is the largest remaining latency in the pipeline (300–960 ms per sentence, ES→EN) and its only unguarded failure point: a translation that never returns stalls its direction for the rest of the call, and a failed one raises a modal alert and loses the sentence. F8.5.4 keeps one Apple `TranslationSession` alive per direction, bounds every request with a timeout and one retry, makes translation independent of the main window, and removes the last unchecked concurrency escapes in STT and Translation.

## Motivation (code reading 2026-10-07)

| ID | Defect | Effect for the user |
|----|--------|---------------------|
| T4 | `TranslationBridgeModel.enqueue` calls `configuration.invalidate()` for every sentence, so SwiftUI re-runs `.translationTask` and builds a new `TranslationSession` each time (`TranslationBridge.swift:38-45`). | 300–960 ms per sentence (measured), on top of VAD ~0.72 s + STT 0.1–0.23 s. |
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
| D-7 | macOS 26 `TranslationSession(installedSource:target:)` (no view) is **out of scope** (YAGNI) unless D-6 shows the persistent bridge cannot reach the target. Deployment target stays macOS 15.0. |

## Functional Requirements

### FR-8.5.4.1 — Persistent session

**REQ-TR-01**: Each direction SHALL have one `TranslationBridgeModel` whose `.translationTask` closure, once fired, SHALL serve translation requests from a FIFO queue until the task is cancelled, without changing or invalidating the configuration between requests.

**REQ-TR-02**: The configuration SHALL be replaced only when (a) the language pair of that direction changes, (b) a warm-up is requested for a pair with no live session, or (c) a rebuild is needed after a failed or timed-out request.

**REQ-TR-03**: Requests SHALL be answered in the order they were submitted. A request pending or in flight when the session is cancelled (pair change, rebuild) SHALL be served by the next session, not failed.

**REQ-TR-04**: A request whose pair differs from the live session's pair SHALL trigger the pair change (REQ-TR-02a) and be served by the new session.

**REQ-TR-05**: `AudioCoordinator.start` SHALL request a warm-up of both directions for the current pair, so the first sentence of a call does not pay the session start-up cost. Warm-up SHALL NOT delay the start of capture.

### FR-8.5.4.2 — Timeout and retry

**REQ-TR-10**: Every translation request SHALL complete (value or error) within the timeout (default 5 s, injectable clock and duration), including when `.translationTask` never fires.

**REQ-TR-11**: On timeout or session error, the bridge SHALL rebuild the session and retry the request once. If the retry also fails, the request SHALL throw `TranslationError.timedOut` or `TranslationError.sessionError`.

**REQ-TR-12**: A failed request SHALL NOT affect later requests: the next request is served by the rebuilt session.

**REQ-TR-13**: Cancelling the caller's task SHALL remove its request from the queue and throw `CancellationError`, without affecting other requests.

### FR-8.5.4.3 — Error reporting in the pipeline

**REQ-TR-20**: When translating one sentence fails with `timedOut` or `sessionError`, the coordinator SHALL skip that sentence, keep processing the next ones, and show a non-modal notice in the existing notice line (e.g. "A sentence could not be translated"), naming the direction.

**REQ-TR-21**: `unsupportedPair` and `modelNotLoaded` SHALL still raise the modal alert, at most once per call session per error kind.

**REQ-TR-22**: `TranslationError.bridgeUnavailable` SHALL be removed: the service holds its bridge model strongly, so the case can no longer occur (a missing view is reported as `timedOut`).

### FR-8.5.4.4 — Hosting independent of the main window

**REQ-TR-30**: Both call-time bridges SHALL be hosted in an off-screen, non-activating window owned by `AppContainer`, created at app launch and kept for the app's lifetime. They SHALL be removed from the `WindowGroup`.

**REQ-TR-31**: Translation SHALL keep working with the main window closed (menu-bar-only operation).

### FR-8.5.4.5 — Language download

**REQ-TR-40**: "Download" in `LanguagePairView` SHALL run `prepareTranslation()` from a `.translationTask` attached to the visible view, so the system download sheet appears in the main window. It SHALL NOT use the call-time bridges.

**REQ-TR-41**: After the download task completes (success or error), `LanguagePairManager.checkAvailability()` SHALL run, and an error SHALL be shown as today (modal alert).

**REQ-TR-42**: `TranslationService.prepare` SHALL be removed from the protocol (its only caller moves to REQ-TR-40).

### FR-8.5.4.6 — Supported pairs (T5)

**REQ-TR-50**: The default `supports` implementation on `TranslationService` SHALL be removed. `AppleTranslationService.supports` SHALL return `true` only for `LanguageAvailability` status `.installed` or `.supported`.

**REQ-TR-51**: `TranslationEngineSelector.supports` SHALL delegate to the service implementation instead of duplicating the check.

### FR-8.5.4.7 — Concurrency hygiene (A10 remainder)

**REQ-TR-60**: No `nonisolated(unsafe)` SHALL remain in `Core/STT` or `Core/Translation`. `locale` in the three STT services SHALL be protected by a lock (`Mutex`) or isolated state; `AppleTranslationService` SHALL hold its bridge without an unchecked escape.

**REQ-TR-61**: An opengrep rule SHALL fail the scan on `nonisolated(unsafe)` under `Core/STT` and `Core/Translation`.

## Non-Functional Requirements

**NFR-TR-01 (latency)**: With a warm session, the translation step for a short sentence (≤ 15 words, installed pair) SHALL take ≤ 150 ms median over 10 sentences, measured by an integration test that also records the per-call-session baseline in `build/reports/latency.json`.

**NFR-TR-02 (no hangs)**: No test or code path SHALL leave a `CheckedContinuation` unresumed; unit tests use injected clocks, never real sleeps.

**NFR-TR-03**: Unit tests SHALL NOT need a real `TranslationSession`: the bridge talks to the session through a small protocol that tests fake.

## Out of Scope

- macOS 26 `TranslationSession(installedSource:target:)` (D-7).
- Other translation engines (Opus-MT, LibreTranslate).
- T2 Whisper `small` / threshold for Ukrainian (own task after F8.5.4).
- Any VAD/STT/TTS latency work.

## Manual checks (user)

- **M1** Normal call ES↔EN: translations appear and are spoken; perceived delay is shorter than before.
- **M2** Close the main window mid-call: translation continues (menu bar); reopen the window, state is consistent.
- **M3** Change the language pair between calls: next call translates in the new pair.
- **M4** Press "Download" for an uninstalled pair: the system sheet appears in the main window; status updates afterwards.
- **M5** During a call, press "Download": no sentence of the call is lost.
