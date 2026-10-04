# F8.5.1 — Capture & Streams — Requirements

> Status: DRAFT — pending user review (2026-10-03)
> Backlog: `specs/m8.5-stabilization/backlog.md` (items A1, A1b, A2, A4, A5, A5b, T1, part of A10)

## Overview

Make both audio capture paths (microphone → outgoing pipeline, system audio via ScreenCaptureKit → incoming pipeline) survive every session lifecycle event: Stop → Start, microphone change mid-session, device unplugged, the call app quitting, and capture errors. Fix the memory-safety and memory-growth defects in the capture code, and make the incoming path testable without `SCRunningApplication`.

## Motivation

The 2026-10-03 audit and code reading found:

| ID | Defect | Effect for the user |
|----|--------|---------------------|
| A1 | `SystemAudioCaptureService.audioStream16kHz` is created once in `init`. Stopping cancels the VAD task iterating it, which terminates the `AsyncStream` for good. | After Stop → Start, incoming translation is silently dead. |
| A1b | `SCStream` is created with `delegate: nil`. | If the call app quits or the stream fails, nobody notices; incoming stays "active" but dead. |
| A2 | `extractPCMBuffer` wraps the `CMSampleBuffer` memory with `bufferListNoCopy` and the buffer escapes into a `Task`. | Use-after-free risk: garbage audio or crash. |
| A4 | `AudioManager.audioStream48kHz` has no consumer and both mic streams are unbounded. | Memory grows ~190 KB/s for the whole session. |
| A5 | `configureEngine()` never sets the input device on `engine.inputNode`. | The microphone picker is decorative: the system default mic is always used. |
| A5b | `selectInput` during a session recreates the streams, but the VAD still iterates the old, finished one. | Changing mic mid-call silently kills outgoing translation. |
| T1 | `start()` requires an `SCRunningApplication`, which tests cannot build. | 5 `AudioCoordinatorTests` are disabled (incl. `stop()` and `updateLanguagePair()` coverage). |

## Decisions taken (brainstorming 2026-10-03)

| ID | Decision |
|----|----------|
| D-1 | M8.5 stabilization is split into sub-features: **F8.5.1 Capture & streams**, F8.5.2 TTS playback, F8.5.3 Half-duplex + VAD, F8.5.4 Translation. Each has its own spec, plan and PR(s). The shared backlog lives in `specs/m8.5-stabilization/backlog.md`. |
| D-2 | Changing the microphone during a session is a **hot swap**: the session continues on the new device without restarting any pipeline. |
| D-3 | No capture app selected ⇒ **no incoming pipeline** (current behavior kept), with an explicit status in the UI. "All system audio" is out of scope. |
| D-4 | Incoming capture failing mid-session ⇒ **degrade and notify**: outgoing keeps running, incoming shows "stopped: <reason>" with a **Retry** action. No automatic retries. |
| D-5 | Architecture: **one stream per capture session, returned by the start call** (approach 1). Stream properties on the capture protocols are removed. |
| D-6 | Strategic platform decisions (macOS 26 / SpeechAnalyzer, Argmax SDK, own audio driver) are out of M8.5. |

## Functional Requirements

### FR-8.5.1.1 — Stream lifecycle

**REQ-C-01**: `AudioCapture.startCapture()` SHALL return a new `AsyncStream<AVAudioPCMBuffer>` (16 kHz mono Float32) for every successful call. `stopCapture()` SHALL finish that stream.

**REQ-C-02**: `SystemAudioCapture.activate(target:)` SHALL return a new `AsyncStream<AVAudioPCMBuffer>` (16 kHz mono Float32) for every successful call. `deactivate()` SHALL finish that stream.

**REQ-C-03**: After any sequence of Start/Stop, the stream handed to a pipeline SHALL deliver captured audio. No stream SHALL be reused across capture sessions.

**REQ-C-04**: The capture protocols SHALL NOT expose stream properties (`audioStream16kHz`, `audioStream48kHz`). The 48 kHz stream SHALL be removed (no consumer).

**REQ-C-05**: Every capture stream SHALL use a bounded buffer of 64 buffers, dropping the oldest when full. The number of dropped buffers SHALL be counted and logged at most once per second per stream.

**REQ-C-06**: No continuation SHALL be force-unwrapped. Streams SHALL be created with `AsyncStream.makeStream(of:bufferingPolicy:)`.

### FR-8.5.1.2 — Microphone selection

**REQ-C-10**: Starting capture SHALL use the device in `AudioManager.selectedInput` (CoreAudio `kAudioOutputUnitProperty_CurrentDevice` on the input node's audio unit), not the system default.

**REQ-C-11**: `selectInput(_:)` during an active capture session SHALL switch the engine to the new device **without finishing the session stream**. The consumer SHALL keep receiving audio through the same iterator.

**REQ-C-12**: If the new device fails to start, `AudioManager` SHALL revert to the previous device, keep the session alive, and surface an error naming the device.

**REQ-C-13**: If the engine stops because the hardware configuration changed (`AVAudioEngineConfigurationChange`, e.g. the selected mic was unplugged), `AudioManager` SHALL restart capture on the selected device if still present, otherwise on the system default input. It SHALL update `selectedInput` and surface a notice. The session stream SHALL stay alive.

### FR-8.5.1.3 — Capture target

**REQ-C-20**: A `CaptureTarget` value type (`Sendable`, `Equatable`) SHALL identify what the incoming pipeline captures. Its only case in this feature is `.app(bundleID: String)`.

**REQ-C-21**: `AudioCoordinator.start` SHALL take `captureTarget: CaptureTarget?` instead of `SCRunningApplication?`. `SystemAudioCaptureService` SHALL resolve the bundle ID to a running application at activation time and throw `SystemAudioCaptureError.targetNotFound(bundleID:)` if it is not running.

**REQ-C-22**: `SetupManager` SHALL provide `captureTarget: CaptureTarget?`, built from the **persisted** bundle ID (not only from the currently running apps). An app that is not running yet then yields `targetNotFound` plus Retry, instead of silently disabling incoming.

### FR-8.5.1.4 — Incoming status, failure and retry

**REQ-C-30**: `AudioCoordinator` SHALL publish `incomingStatus: IncomingStatus` with the cases `.idle` (no session), `.disabled` (no capture target), `.starting`, `.active` and `.stopped(IncomingStopReason)`. `isIncomingActive` SHALL be derived from it (`== .active`).

**REQ-C-31**: `IncomingStopReason` SHALL distinguish `targetNotFound(bundleID)`, `permissionDenied` and `streamError(String)`. Each SHALL have a user-facing message.

**REQ-C-32**: `SystemAudioCaptureService` SHALL implement `SCStreamDelegate.stream(_:didStopWithError:)`. On that callback it SHALL finish the session stream, become inactive and emit `.stopped(reason)` on a `nonisolated var events: AsyncStream<SystemCaptureEvent>` that lives as long as the service.

**REQ-C-33**: When incoming capture stops mid-session, the coordinator SHALL deactivate the incoming VAD/STT/TTS and set `.stopped(reason)`. Outgoing SHALL keep running and `isIncomingSpeaking` SHALL become `false`.

**REQ-C-34**: `AudioCoordinator.retryIncoming(captureTarget:)` SHALL act only during a session, in `.stopped`, or in `.disabled` once a capture target exists (amended in the final review: Retry uses the call app chosen now, and choosing one recovers `.disabled`). It SHALL set `.starting` synchronously before any `await`, so concurrent calls are no-ops, and re-run incoming activation with a fresh stream.

**REQ-C-35**: If `stop()` runs while an incoming activation (start or retry) is in flight, the activation SHALL tear down whatever it created once it resumes, and `incomingStatus` SHALL end as `.idle`.

**REQ-C-36**: The main window and the menu-bar popover SHALL show the incoming status: hidden when `.active`/`.idle`. For `.disabled` they show "Incoming off — choose the call app". For `.stopped` they show "Incoming stopped: <reason>" with a **Retry** button.

### FR-8.5.1.5 — Memory safety

**REQ-C-40**: Buffers extracted from `CMSampleBuffer` SHALL own their memory: samples are copied into a newly allocated `AVAudioPCMBuffer` inside the `withAudioBufferList` scope. `bufferListNoCopy` SHALL NOT appear in production code.

**REQ-C-41**: In every file this feature touches, each `nonisolated(unsafe)` SHALL either be removed or carry a `// SAFETY:` justification. `cont!` SHALL be eliminated.

## Non-Functional Requirements

**NFR-C-01**: A microphone hot swap SHALL lose at most 500 ms of audio (measured in the integration test).

**NFR-C-02**: Memory used by the capture streams SHALL be bounded regardless of session length (≤ 64 buffers per stream).

**NFR-C-03**: The audio tap and SCStream callbacks SHALL NOT block, take locks shared with the MainActor, or `await`.

## Out of Scope

- "All system audio" as a capture target.
- Automatic retry of incoming capture.
- Half-duplex echo leak (A6), Silero VAD (A7), VAD config (T3, T4) → F8.5.3.
- TTS defects (A3, A9, A11, T6) → F8.5.2. Translation defects (A8, T4, T5) → F8.5.4.
- Promoting `asyncstream-unbounded` to ERROR: Core/TTS occurrences remain until F8.5.2.

## Acceptance Criteria

1. `just pr` passes on the feature branch.
2. No `.disabled("F8.5.1: …")` remains in `AudioCoordinatorTests`. The 5 tests pass against `CaptureTarget`.
3. New unit tests cover: Stop → Start fresh stream (A1), stream-error stop + Retry + double Retry + stop-during-retry (A1b, REQ-C-34/35), owned-memory extraction (A2), bounded stream drop counting (A4), mic fallback choice (REQ-C-13). A5b is pinned by integration test (criterion 4).
4. Integration tier: with BlackHole 2ch as input, `CurrentDevice` equals BlackHole and fixture audio played into BlackHole reaches the stream (A5). A hot swap default → BlackHole keeps the same iterator delivering audio (A5b, NFR-C-01). A missing BlackHole **fails** with an actionable message.
5. opengrep: `buffer-nocopy-escape` promoted to ERROR. Zero `asyncstream-unbounded`, `asyncstream-force-unwrap` and `nonisolated-unsafe-justified` findings under `TranslateCall/Core/Audio/`.
6. Manual checklist (in `tasks.md`) completed with Zoom or FaceTime: Stop → Start keeps incoming working, closing the call app shows "stopped" while outgoing still works, Retry after reopening restores incoming, unplugging the selected mic falls back to the default with a notice.
