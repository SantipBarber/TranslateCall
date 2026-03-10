# F4.2 – Half-Duplex Echo Management

**Milestone**: M4 – Full Pipeline Integration
**Feature**: F4.2 – Half-Duplex Echo Management
**Status**: DRAFT – Pending Gate 1 Review
**Date**: 2026-03-10
**Depends on**: F4.1 (Bidirectional Pipeline — `AudioCoordinator` with `suppressIncomingPipeline` / `suppressOutgoingCapture` stubs)

---

## 1. Context & Motivation

F4.1 establishes a bidirectional pipeline with two audio paths running concurrently:

```
[Outgoing] Mic ──▶ VAD ──▶ STT ──▶ Translate ──▶ TTS(B) ──▶ BlackHole ──▶ Remote
[Incoming] SCStream ──▶ VAD ──▶ STT ──▶ Translate ──▶ TTS(A) ──▶ Speakers ──▶ User
```

Two feedback loops emerge when both run without coordination:

1. **Mic feedback**: Incoming TTS speaks through local speakers → local microphone picks it up → outgoing pipeline re-transcribes and re-translates the computer's own voice → infinite loop.
2. **BlackHole loopback**: Outgoing TTS routes to BlackHole. If the system audio capture for the incoming pipeline reads BlackHole's output (e.g., via a Multi-Output / Aggregate device), the outgoing TTS gets re-ingested by the incoming pipeline → loopback echo.

PoC5 validated a software half-duplex approach: a 3-state machine that suppresses the appropriate capture while any TTS is active, then waits a 300ms settling buffer before re-enabling it. 6/6 tests passed, 315ms average transition latency (well within the 400ms budget).

F4.2 implements this validated design as a production `HalfDuplexManager` integrated with `AudioCoordinator`.

---

## 2. Scope

**In scope for F4.2**:
- `HalfDuplexManager`: `@MainActor` component observing both TTS speaking states and controlling capture suppression
- 3-state machine: `.listening` → `.speaking` → `.transitioning` → `.listening`
- Rule: incoming TTS active → suppress outgoing mic capture
- Rule: outgoing TTS active → suppress incoming system audio capture
- 300ms settling buffer after TTS ends before re-enabling capture
- Concurrent transition handling: new speaking event while transitioning cancels buffer and stays in `.speaking`
- UI: `StatusBadgeView` reflects half-duplex state (green/red/yellow)
- Configurable transition delay (default 300ms, injectable for tests)

**Out of scope for F4.2**:
- Hardware AEC (not available with the BlackHole routing architecture — see C-4.1.6)
- Suppressing ongoing TTS playback when the other pipeline starts (TTS completes; suppression only blocks new input capture)
- Per-pipeline volume ducking / fade effects (M5 polish)
- Video call integration and setup wizard (F4.3)

---

## 3. Functional Requirements

### 3.1 State Machine

**FR-4.2.1** The `HalfDuplexManager` SHALL maintain one of three states:
- `.listening` — no TTS active; both outgoing capture and incoming capture enabled
- `.speaking` — at least one TTS active; appropriate captures suppressed (see FR-4.2.4 / FR-4.2.5)
- `.transitioning` — all TTS just finished; captures still suppressed while waiting for the settling buffer to elapse

**FR-4.2.2** WHEN `isOutgoingSpeaking` transitions from `false` to `true` OR `isIncomingSpeaking` transitions from `false` to `true` THEN the manager SHALL:
1. Cancel any pending `.transitioning` buffer task
2. Transition to `.speaking` immediately (no delay)
3. Apply capture suppression as per FR-4.2.4 / FR-4.2.5

**FR-4.2.3** WHEN BOTH `isOutgoingSpeaking` AND `isIncomingSpeaking` become `false` THEN the manager SHALL:
1. Transition to `.transitioning`
2. Start a buffer task that waits for the configured `transitionDelay` (default 300ms)
3. After the buffer elapses, transition to `.listening` and lift all capture suppression

**FR-4.2.4** WHILE `isIncomingSpeaking` is `true` THEN the manager SHALL call `coordinator.suppressOutgoingCapture(true)` to mute the local microphone.

**FR-4.2.5** WHILE `isOutgoingSpeaking` is `true` THEN the manager SHALL call `coordinator.suppressIncomingPipeline(true)` to pause the system audio capture.

**FR-4.2.6** WHEN transitioning to `.listening` THEN the manager SHALL call both `coordinator.suppressOutgoingCapture(false)` and `coordinator.suppressIncomingPipeline(false)` to re-enable all capture.

**FR-4.2.7** WHEN a new TTS speaking event arrives WHILE the manager is in `.transitioning` state THEN the pending buffer task SHALL be cancelled and the manager SHALL remain in `.speaking` with suppression active. (No redundant `listening` flash.)

### 3.2 AudioCoordinator Integration

**FR-4.2.8** `AudioCoordinator.suppressOutgoingCapture(_ suppress: Bool)` SHALL, when `suppress == true`, cause the outgoing pipeline's VAD to discard all incoming audio buffers until suppression is lifted; it SHALL NOT deactivate or restart the VAD or STT service.

**FR-4.2.9** `AudioCoordinator.suppressIncomingPipeline(_ suppress: Bool)` SHALL, when `suppress == true`, cause the incoming pipeline's VAD to discard all incoming audio buffers until suppression is lifted; it SHALL NOT deactivate or restart the VAD or STT service.

> **Implementation note**: The simplest implementation is a `@MainActor var isSuppressed: Bool` flag on the coordinator checked before passing buffers to the VAD. Buffers are silently dropped; no error is emitted.

**FR-4.2.10** The `HalfDuplexManager` SHALL be created inside `AppContainer` and receive a weak reference to `AudioCoordinator` via `init`. It SHALL be activated when the coordinator starts and deactivated when the coordinator stops.

**FR-4.2.11** `AudioViewModel` SHALL expose `halfDuplexState: HalfDuplexState` as a `@Published` property bound from `HalfDuplexManager.state`, for UI consumption.

### 3.3 UI

**FR-4.2.12** `StatusBadgeView` SHALL reflect `halfDuplexState`:
- `.listening` → existing green pulsing indicator (no change)
- `.speaking` → red indicator, mic icon replaced by muted-mic icon (`mic.slash`)
- `.transitioning` → yellow/orange indicator with clock icon, label "Transitioning…"

**FR-4.2.13** WHEN the pipeline is stopped (not capturing) THE existing grey/idle indicator SHALL be shown regardless of `halfDuplexState`.

---

## 4. Non-Functional Requirements

### 4.1 Performance

**NFR-4.2.1** The transition from TTS-end to capture-resume SHALL complete within 400ms (300ms buffer + ≤100ms overhead), consistent with PoC5 measurement of 315ms.

**NFR-4.2.2** Buffer task creation and cancellation SHALL incur no allocations on the audio processing path. All state changes SHALL happen on `@MainActor`.

**NFR-4.2.3** Suppressed audio buffers SHALL be silently discarded with no heap allocation per discarded buffer.

### 4.2 Correctness

**NFR-4.2.4** The state machine SHALL be deterministic: given the same sequence of `isOutgoingSpeaking` / `isIncomingSpeaking` events, it SHALL always produce the same state transitions regardless of scheduling jitter.

**NFR-4.2.5** There SHALL be no state where captures are enabled while TTS is active.

**NFR-4.2.6** There SHALL be no state where captures are suppressed after the transition buffer has elapsed (no stuck suppression).

---

## 5. Constraints

**C-4.2.1** `HalfDuplexManager` MUST run on `@MainActor` because it reads and writes `AudioCoordinator`'s `@Published` properties and calls its methods.

**C-4.2.2** The buffer Task uses `Task.sleep(for:)` (Swift 6 API, macOS 15+). Task cancellation via `.cancel()` is relied upon for preemption — the Task MUST check `Task.isCancelled` or use a `throws`-based sleep that throws `CancellationError`.

**C-4.2.3** `suppressOutgoingCapture` and `suppressIncomingPipeline` MUST be idempotent — calling them multiple times with the same value SHALL be safe.

**C-4.2.4** The coordinator's audio buffer tap runs on a background audio thread. The suppression check (flag read) MUST be thread-safe. A `@MainActor var` can only be safely read on the main actor; use a separate `nonisolated(unsafe)` flag or synchronize via an atomic if the check must happen off-MainActor.

> **Preferred approach**: Use a simple `var outgoingCaptureSuppressed: Bool` and `var incomingCaptureSuppressed: Bool` that are read in the audio tap closure. Since macOS audio taps run on a high-priority thread and the flag is set from MainActor, they need `nonisolated(unsafe)` (same pattern as `SyncBox` in AudioManager). This is safe because the worst case is one extra buffer processed after suppression is set.

---

## 6. Acceptance Criteria

| ID | Criterion | Test Method |
|----|-----------|-------------|
| AC-4.2.1 | `.listening` → `.speaking` when either TTS starts; no delay | Unit: inject `isIncomingSpeaking=true`, assert state == .speaking synchronously |
| AC-4.2.2 | `.speaking` → `.transitioning` → `.listening` after 300ms when both TTS stop | Unit: inject false for both, wait >300ms, assert state == .listening |
| AC-4.2.3 | New TTS start during `.transitioning` cancels buffer and stays `.speaking` | Unit: start transition, inject new speaking=true within 100ms, assert state stays .speaking after 300ms |
| AC-4.2.4 | `suppressOutgoingCapture(true)` called when incoming TTS starts | Unit: mock coordinator, assert call received on isIncomingSpeaking=true |
| AC-4.2.5 | `suppressIncomingPipeline(true)` called when outgoing TTS starts | Unit: mock coordinator, assert call received on isOutgoingSpeaking=true |
| AC-4.2.6 | Both suppressions lifted when transitioning to `.listening` | Unit: verify both suppress(false) called after buffer elapses |
| AC-4.2.7 | `StatusBadgeView` shows red + mic.slash in `.speaking` state | UI test / manual: verify visual |
| AC-4.2.8 | `StatusBadgeView` shows yellow + clock in `.transitioning` state | UI test / manual: verify visual |
| AC-4.2.9 | `StatusBadgeView` shows green in `.listening` state | Existing behavior unchanged |
| AC-4.2.10 | No audio feedback loop in end-to-end session (empirical) | Manual: run full session, verify no echo/loopback |

---

## 7. Open Questions

| # | Question | Owner | Status |
|---|----------|-------|--------|
| OQ-1 | Should suppression pause the VAD's `AsyncStream` continuation (backpressure) or continue consuming buffers and silently drop them? Dropping is simpler; pausing would reduce CPU. | Architecture | **Tentative: drop silently. VAD is energy-based (cheap), stream rate is low (160 buffers/s at 16kHz/100ms chunks).** |
| OQ-2 | Should the `HalfDuplexManager` be visible to `AudioViewModel` directly, or only via coordinator-proxied `@Published` properties? | Architecture | **Tentative: expose via coordinator for clean layering — coordinator owns the manager, ViewModel binds to coordinator.** |
| OQ-3 | 300ms buffer is adequate when both pipelines are active. Should the buffer be asymmetric — shorter (150ms) for outgoing-only sessions where no incoming TTS feeds local speakers? | UX/Perf | **Defer to M5 tuning. Use 300ms uniformly for MVP.** |

---

## 8. Dependencies on Other Features

| Feature | Dependency Type | Notes |
|---------|----------------|-------|
| F4.1 AudioCoordinator | Extension | `suppressIncomingPipeline` / `suppressOutgoingCapture` stubs become real implementations |
| F4.1 AudioCoordinator | Observe | `isOutgoingSpeaking` / `isIncomingSpeaking` @Published drive the state machine |
| F4.3 Video Call Integration | Downstream | Half-duplex visual state indicator will be visible to user during calls |

---

*End of F4.2 Requirements — Gate 1 Review Pending*
