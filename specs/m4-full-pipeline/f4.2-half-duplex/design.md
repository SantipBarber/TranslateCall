# F4.2 – Half-Duplex Echo Management: Design

**Milestone**: M4 – Full Pipeline Integration
**Feature**: F4.2 – Half-Duplex Echo Management
**Status**: DRAFT – Pending Gate 2 Review
**Date**: 2026-03-10
**Depends on**: requirements.md (F4.2), F4.1 implementation

---

## 1. Architecture Overview

```
AppContainer
  └─ AudioCoordinator (@MainActor ObservableObject)
       ├─ $isOutgoingSpeaking ──┐
       ├─ $isIncomingSpeaking ──┤──▶  HalfDuplexManager (@MainActor)
       ├─ suppressOutgoingCapture() ◀──┘     └─▶ $state (.listening/.speaking/.transitioning)
       └─ suppressIncomingPipeline() ◀──┘
                                              ▼
AudioViewModel (@MainActor ObservableObject)
  └─ $halfDuplexState  ◀── bindCoordinator() via Combine assign(to:)

StatusBadgeView
  └─ halfDuplexState: HalfDuplexState
```

**Key invariant**: All state transitions in `HalfDuplexManager` happen on `@MainActor`. The coordinator's suppression flags are written on `@MainActor` and read on the audio thread via `nonisolated(unsafe)`.

---

## 2. New Types

### 2.1 `HalfDuplexState`

```swift
// Core/Audio/HalfDuplexManager.swift

enum HalfDuplexState: Equatable {
    case listening
    case speaking
    case transitioning
}
```

Lives in `Core/Audio/HalfDuplexManager.swift`. `Equatable` for `.animation(value:)` and test assertions.

---

### 2.2 `HalfDuplexManager`

```swift
@MainActor
final class HalfDuplexManager {

    // MARK: - Public state
    private(set) var state: HalfDuplexState = .listening

    // MARK: - Configuration
    let transitionDelay: Duration   // default: .milliseconds(300)

    // MARK: - Private
    private weak var coordinator: AudioCoordinator?
    private var bufferTask: Task<Void, Never>?
    private var observations: [AnyCancellable] = []

    // MARK: - Init
    init(coordinator: AudioCoordinator, transitionDelay: Duration = .milliseconds(300)) {
        self.coordinator = coordinator
        self.transitionDelay = transitionDelay
        bindCoordinator()
    }

    // MARK: - Activation
    func activate() { /* already bound on init — no-op, reserved for future */ }
    func deactivate() {
        bufferTask?.cancel()
        bufferTask = nil
        observations.removeAll()
        // Lift any in-flight suppression (coordinator may have been stopped)
        coordinator?.suppressOutgoingCapture(false)
        coordinator?.suppressIncomingPipeline(false)
    }
}
```

**Why `@MainActor` class (not actor)?**
`AudioCoordinator` is `@MainActor ObservableObject`. All interaction is on the main actor. Using a plain `@MainActor final class` keeps the design consistent with `AudioCoordinator` and `AudioViewModel`, and avoids `await` for every state read.

**Lifecycle**: Created by `AudioCoordinator.init`, bound immediately. Deactivated in `AudioCoordinator.stop()`.

---

### 2.3 State Machine Logic

```
                  isOutgoingSpeaking OR isIncomingSpeaking = true
                  ────────────────────────────────────────────────▶
         ┌──────────────────┐                         ┌──────────────────┐
         │    .listening    │                         │    .speaking     │
         └──────────────────┘                         └──────────────────┘
                  ◀────────────────────────────────────────────────
                                                       both = false
                                                            │
                                                            ▼
                                                  ┌──────────────────────┐
                                                  │   .transitioning     │
                                                  │  (300ms buffer task) │
                                                  └──────────────────────┘
                                                       │           │
                                              buffer   │           │  new speaking = true
                                              elapsed  │           │  (cancel task)
                                                       ▼           ▼
                                                  .listening    .speaking
```

**Transition rules**:

| Current State | Event | Next State | Side Effect |
|---|---|---|---|
| `.listening` | any `isSpeaking = true` | `.speaking` | apply suppressions |
| `.speaking` | both `isSpeaking = false` | `.transitioning` | start buffer task |
| `.speaking` | other `isSpeaking = true` | `.speaking` | update suppressions only |
| `.transitioning` | any `isSpeaking = true` | `.speaking` | cancel task, apply suppressions |
| `.transitioning` | buffer elapsed | `.listening` | lift all suppressions |

**Suppression rules** (applied on every `.speaking` entry and on suppression updates):

```
isIncomingSpeaking → suppressOutgoingCapture(true)    // mic mute
isOutgoingSpeaking → suppressIncomingPipeline(true)   // loopback prevention
!isIncomingSpeaking && !isOutgoingSpeaking → lift all  // only on .listening entry
```

Note: when only ONE pipeline is speaking, only ONE suppression is needed. Example: if only incoming TTS is active, the outgoing capture (mic) is suppressed but the incoming capture (system audio) remains enabled. This is correct: remote audio can still flow in but won't create new TTS output (because the outgoing pipeline is suppressed, so the mic can't feed a new translation cycle).

---

## 3. Changes to `AudioCoordinator`

### 3.1 Suppression flags

```swift
// In AudioCoordinator.swift

// nonisolated(unsafe) because they are written on @MainActor (bindCoordinator/suppressX calls)
// and read on the audio thread inside the engine tap (configureEngine is nonisolated).
// Safe by design: worst case is one extra buffer processed after flag is set.
nonisolated(unsafe) private(set) var outgoingCaptureSuppressed: Bool = false
nonisolated(unsafe) private(set) var incomingCaptureSuppressed: Bool = false
```

### 3.2 `suppressOutgoingCapture` and `suppressIncomingPipeline` implementations

```swift
func suppressOutgoingCapture(_ suppress: Bool) {
    outgoingCaptureSuppressed = suppress
}

func suppressIncomingPipeline(_ suppress: Bool) {
    incomingCaptureSuppressed = suppress
}
```

### 3.3 Buffer-level suppression check

The outgoing pipeline feeds audio buffers from `audioCapture.audioStream16kHz` to the VAD. The incoming pipeline feeds buffers from `systemCapture.audioStream` to the incoming VAD. The suppression check is inserted at the head of each observation loop:

```swift
// Outgoing VAD observation (existing in startOutgoingPipeline):
Task { [weak self] in
    for await buffer in audioCapture.audioStream16kHz {
        guard let self, !self.outgoingCaptureSuppressed else { continue }
        await outgoingVAD.process(buffer)
    }
}

// Incoming VAD observation (existing in startIncomingPipeline):
Task { [weak self] in
    for await buffer in systemCapture.audioStream {
        guard let self, !self.incomingCaptureSuppressed else { continue }
        await incomingVAD.process(buffer)
    }
}
```

This is a non-allocating, branch-predicted fast path. When `suppressed == false` (the common case), the guard is almost free.

### 3.4 `HalfDuplexManager` ownership

```swift
// In AudioCoordinator:
private let halfDuplexManager: HalfDuplexManager

// In init (after self is fully initialized):
self.halfDuplexManager = HalfDuplexManager(coordinator: self, transitionDelay: transitionDelay)

// Expose state for binding:
var halfDuplexState: HalfDuplexState { halfDuplexManager.state }
// Or, if UI needs @Published reactivity, republish:
@Published private(set) var halfDuplexState: HalfDuplexState = .listening
// updated in HalfDuplexManager via callback or Combine
```

**Preferred approach**: `HalfDuplexManager` holds a closure or weak ref back to coordinator to update `halfDuplexState`. Alternatively, coordinator observes manager's state via KVO or a delegate callback. Simplest: the manager calls `coordinator.halfDuplexStateDidChange(_:)` on every transition.

---

## 4. Changes to `AudioViewModel`

Add to `bindCoordinator()`:

```swift
coordinator.$halfDuplexState.assign(to: &$halfDuplexState)
```

New property:

```swift
@Published private(set) var halfDuplexState: HalfDuplexState = .listening
```

---

## 5. Changes to `StatusBadgeView`

Replace `isSpeechActive`/`isSpeaking` gating with `halfDuplexState`:

```swift
struct StatusBadgeView: View {
    var isCapturing: Bool
    var isSpeechActive: Bool        // existing — VAD triggered
    var halfDuplexState: HalfDuplexState = .listening
    var isIncomingActive: Bool = false

    // Derived:
    private var indicatorColor: Color {
        guard isCapturing else { return .secondary }
        switch halfDuplexState {
        case .listening:    return isSpeechActive ? .orange : .green
        case .speaking:     return .red
        case .transitioning: return .yellow
        }
    }

    private var indicatorIcon: String {
        switch halfDuplexState {
        case .listening:    return "mic"
        case .speaking:     return "mic.slash"
        case .transitioning: return "clock"
        }
    }

    private var label: String {
        guard isCapturing else { return "Idle" }
        switch halfDuplexState {
        case .listening:    return isSpeechActive ? "Speech detected" : "Listening"
        case .speaking:     return "Speaking"
        case .transitioning: return "Transitioning…"
        }
    }
}
```

---

## 6. File Map

| File | Change | Notes |
|------|--------|-------|
| `Core/Audio/HalfDuplexManager.swift` | **CREATE** | State machine, Combine bindings, buffer task |
| `Core/Audio/AudioCoordinator.swift` | **MODIFY** | Implement stubs, add flags, create/hold manager, republish state |
| `Features/Main/AudioViewModel.swift` | **MODIFY** | Add `halfDuplexState` published, bind in `bindCoordinator()` |
| `Features/Main/StatusBadgeView.swift` | **MODIFY** | Replace `isSpeaking` with `halfDuplexState`, update icons and colors |
| `Features/ContentView.swift` | **MODIFY** | Pass `halfDuplexState` to `StatusBadgeView` |
| `TranslateCallTests/HalfDuplexManagerTests.swift` | **CREATE** | Unit tests for state machine |
| `TranslateCallTests/Mocks/MockHalfDuplexCoordinator.swift` | **CREATE** | Minimal mock to track suppress calls |

---

## 7. `HalfDuplexManager` — Full Design

```swift
@MainActor
final class HalfDuplexManager {

    enum State: Equatable {
        case listening, speaking, transitioning
    }

    // Written on @MainActor, read from anywhere (UI + coordinator)
    private(set) var state: State = .listening {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((State) -> Void)?  // coordinator updates halfDuplexState via this

    let transitionDelay: Duration
    private weak var coordinator: AudioCoordinator?
    private var bufferTask: Task<Void, Never>?
    private var observations: [AnyCancellable] = []

    init(coordinator: AudioCoordinator, transitionDelay: Duration = .milliseconds(300)) {
        self.coordinator = coordinator
        self.transitionDelay = transitionDelay
        bind()
    }

    private func bind() {
        // Observe both isSpeaking publishers on coordinator
        coordinator?.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluateSpeakingState() }
            .store(in: &observations)
        // OR observe specific @Published properties (more explicit):
        // coordinator?.$isOutgoingSpeaking.combineLatest(coordinator?.$isIncomingSpeaking)
        //     .sink { ... }
    }

    private func evaluateSpeakingState() {
        guard let coordinator else { return }
        let outgoing = coordinator.isOutgoingSpeaking
        let incoming = coordinator.isIncomingSpeaking

        if outgoing || incoming {
            handleSpeakingActive(outgoing: outgoing, incoming: incoming)
        } else if state == .speaking {
            handleAllSpeakingEnded()
        }
    }

    private func handleSpeakingActive(outgoing: Bool, incoming: Bool) {
        bufferTask?.cancel()
        bufferTask = nil
        state = .speaking
        coordinator?.suppressOutgoingCapture(incoming)   // mic mute when incoming TTS speaks
        coordinator?.suppressIncomingPipeline(outgoing)  // loopback block when outgoing TTS speaks
    }

    private func handleAllSpeakingEnded() {
        state = .transitioning
        bufferTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.transitionDelay)
            } catch {
                return  // cancelled — a new speaking event arrived
            }
            self.state = .listening
            self.coordinator?.suppressOutgoingCapture(false)
            self.coordinator?.suppressIncomingPipeline(false)
            self.bufferTask = nil
        }
    }

    func deactivate() {
        bufferTask?.cancel()
        bufferTask = nil
        observations.removeAll()
        coordinator?.suppressOutgoingCapture(false)
        coordinator?.suppressIncomingPipeline(false)
        state = .listening
    }
}
```

**Notes**:
- `objectWillChange` approach fires before state changes, which causes a one-cycle lag. The more explicit `combineLatest($isOutgoingSpeaking, $isIncomingSpeaking)` is preferred for correctness. See tasks for the final choice.
- `bufferTask?.cancel()` is always safe to call even if task is nil or already completed.
- `Task.sleep(for:)` throws `CancellationError` when task is cancelled — the `catch { return }` handles this cleanly.

---

## 8. Test Strategy

**Unit tests** (`HalfDuplexManagerTests.swift`):

```
@Suite("HalfDuplexManager", .serialized) @MainActor
```

All tests use a `MockHalfDuplexCoordinator` that:
- Has `isOutgoingSpeaking: Bool` and `isIncomingSpeaking: Bool` (settable in tests)
- Tracks `suppressOutgoingCaptureCalls: [Bool]` and `suppressIncomingPipelineCalls: [Bool]`
- Exposes a `$isOutgoingSpeaking` and `$isIncomingSpeaking` PassthroughSubject for Combine binding

Test cases:
1. `initialStateIsListening` — state == .listening at init
2. `incomingSpeakingTriggersSpeak` — inject incoming=true → state == .speaking
3. `outgoingSpeakingTriggersSpeak` — inject outgoing=true → state == .speaking
4. `incomingSpeakingMutesMic` — verify `suppressOutgoingCapture(true)` called
5. `outgoingSpeakingBlocksLoopback` — verify `suppressIncomingPipeline(true)` called
6. `bothStopTransitionsToListeningAfterDelay` — inject false for both, wait > delay, assert .listening
7. `newSpeakingCancelsTransitionBuffer` — stop → start new TTS within delay → stays .speaking
8. `deactivateLiftsSuppression` — call deactivate() while .speaking, verify suppress(false) called

Use `transitionDelay: .milliseconds(50)` in tests to avoid 300ms waits.

---

## 9. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Suppression flag read race on audio thread | Low | Low | `nonisolated(unsafe)` + worst-case 1 extra buffer processed — acceptable |
| Buffer task leaks if coordinator deallocated mid-transition | Low | Medium | `weak var coordinator` guard at task start; task auto-cancels on object release |
| Combine `combineLatest` fires spurious events | Low | Low | State machine is idempotent for same-state transitions |
| 300ms transition too long for fast speakers | Medium | UX | Configurable delay; M5 tuning with real user testing |

---

*End of F4.2 Design — Gate 2 Review Pending*
