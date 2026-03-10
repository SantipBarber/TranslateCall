# F4.2 – Half-Duplex Echo Management: Tasks

**Milestone**: M4 – Full Pipeline Integration
**Feature**: F4.2 – Half-Duplex Echo Management
**Status**: DRAFT – Pending Gate 3 Review
**Date**: 2026-03-10

---

## Task Summary

| ID | Title | Files | Depends |
|----|-------|-------|---------|
| T1 | `HalfDuplexState` enum + `HalfDuplexManager` skeleton | `Core/Audio/HalfDuplexManager.swift` | — |
| T2 | Implement suppression flags in `AudioCoordinator` | `Core/Audio/AudioCoordinator.swift` | T1 |
| T3 | Implement state machine logic in `HalfDuplexManager` | `Core/Audio/HalfDuplexManager.swift` | T2 |
| T4 | Wire buffer-level suppression in `AudioCoordinator` | `Core/Audio/AudioCoordinator.swift` | T2 |
| T5 | Wire `HalfDuplexManager` into `AudioCoordinator` lifecycle | `Core/Audio/AudioCoordinator.swift` | T3 |
| T6 | Propagate `halfDuplexState` to `AudioViewModel` | `Features/Main/AudioViewModel.swift` | T5 |
| T7 | Update `StatusBadgeView` for half-duplex states | `Features/Main/StatusBadgeView.swift`, `Features/ContentView.swift` | T6 |
| T8 | Unit tests for `HalfDuplexManager` | `TranslateCallTests/HalfDuplexManagerTests.swift`, `TranslateCallTests/Mocks/MockHalfDuplexCoordinator.swift` | T3 |
| T9 | End-to-end smoke test + commit | — | T1–T8 |

---

## T1 — `HalfDuplexState` enum + `HalfDuplexManager` skeleton

**File**: `TranslateCall/Core/Audio/HalfDuplexManager.swift` (CREATE)

### Checklist

- [ ] Define `HalfDuplexState: Equatable` enum with `.listening`, `.speaking`, `.transitioning` cases
- [ ] Define `@MainActor final class HalfDuplexManager` with:
  - `private(set) var state: HalfDuplexState = .listening`
  - `var onStateChange: ((HalfDuplexState) -> Void)?`
  - `let transitionDelay: Duration`
  - `private weak var coordinator: AudioCoordinator?`
  - `private var bufferTask: Task<Void, Never>?`
  - `private var observations: [AnyCancellable] = []`
  - `init(coordinator: AudioCoordinator, transitionDelay: Duration = .milliseconds(300))`
  - `func deactivate()` — cancel task, remove observations, lift suppressions, reset to .listening
- [ ] `state` property setter calls `onStateChange?(state)` via `didSet`
- [ ] Build passes

---

## T2 — Suppression flags in `AudioCoordinator`

**File**: `TranslateCall/Core/Audio/AudioCoordinator.swift` (MODIFY)

### Checklist

- [ ] Add two `nonisolated(unsafe) private(set) var outgoingCaptureSuppressed: Bool = false`
- [ ] Add two `nonisolated(unsafe) private(set) var incomingCaptureSuppressed: Bool = false`
- [ ] Replace no-op stub `suppressOutgoingCapture(_ suppress: Bool)` with real implementation: `outgoingCaptureSuppressed = suppress`
- [ ] Replace no-op stub `suppressIncomingPipeline(_ suppress: Bool)` with real implementation: `incomingCaptureSuppressed = suppress`
- [ ] Add `@Published private(set) var halfDuplexState: HalfDuplexState = .listening`
- [ ] Build passes

---

## T3 — State machine logic in `HalfDuplexManager`

**File**: `TranslateCall/Core/Audio/HalfDuplexManager.swift` (MODIFY)

### Checklist

- [ ] In `init`, after storing coordinator, call `bind()` immediately
- [ ] Implement `private func bind()`:
  - Obtain both `$isOutgoingSpeaking` and `$isIncomingSpeaking` publishers from coordinator
  - Use `Publishers.CombineLatest` to merge them
  - `.receive(on: RunLoop.main)` (ensure @MainActor)
  - `.sink { [weak self] outgoing, incoming in self?.handle(outgoing: outgoing, incoming: incoming) }`
  - Store `AnyCancellable` in `observations`
- [ ] Implement `private func handle(outgoing: Bool, incoming: Bool)`:
  - If `outgoing || incoming`: call `handleSpeakingActive(outgoing:incoming:)`
  - If `!outgoing && !incoming && state == .speaking`: call `handleAllSpeakingEnded()`
- [ ] Implement `private func handleSpeakingActive(outgoing: Bool, incoming: Bool)`:
  - `bufferTask?.cancel(); bufferTask = nil`
  - `state = .speaking`
  - `coordinator?.suppressOutgoingCapture(incoming)` — mute mic when incoming TTS speaks
  - `coordinator?.suppressIncomingPipeline(outgoing)` — block loopback when outgoing TTS speaks
- [ ] Implement `private func handleAllSpeakingEnded()`:
  - `state = .transitioning`
  - Create `bufferTask = Task { [weak self] in ... }` that:
    - `try await Task.sleep(for: self.transitionDelay)` in a do/catch where catch returns (cancellation)
    - On success: `self.state = .listening`, call both `suppress(false)`, set `self.bufferTask = nil`
- [ ] Verify `deactivate()` calls both `suppress(false)`, cancels task, clears observations, resets state
- [ ] Build passes

---

## T4 — Buffer-level suppression in `AudioCoordinator`

**File**: `TranslateCall/Core/Audio/AudioCoordinator.swift` (MODIFY)

### Checklist

- [ ] In `startOutgoingPipeline()`, locate the Task that iterates `audioCapture.audioStream16kHz` and feeds `outgoingVAD`. Add guard: `guard !self.outgoingCaptureSuppressed else { continue }` before passing each buffer
- [ ] In `startIncomingPipeline()`, locate the Task that iterates `systemCapture.audioStream` (or equivalent) and feeds `incomingVAD`. Add guard: `guard !self.incomingCaptureSuppressed else { continue }` before passing each buffer
- [ ] Verify both guards use `nonisolated(unsafe)` flag directly (no `await` or actor hop)
- [ ] Build passes, existing tests still pass

---

## T5 — Wire `HalfDuplexManager` into `AudioCoordinator` lifecycle

**File**: `TranslateCall/Core/Audio/AudioCoordinator.swift` (MODIFY)

### Checklist

- [ ] Add `private let halfDuplexManager: HalfDuplexManager` stored property
- [ ] In `AudioCoordinator.init(...)`, after `self` is fully initialized, instantiate:
  ```swift
  halfDuplexManager = HalfDuplexManager(coordinator: self, transitionDelay: transitionDelay)
  ```
  (Add `transitionDelay: Duration = .milliseconds(300)` parameter to coordinator init for testability)
- [ ] In `HalfDuplexManager.init` body (called from coordinator init), set `onStateChange`:
  ```swift
  halfDuplexManager.onStateChange = { [weak self] state in
      self?.halfDuplexState = state
  }
  ```
  OR coordinate via a callback passed to manager init. Either approach is fine.
- [ ] In `AudioCoordinator.stop()`, call `halfDuplexManager.deactivate()` before stopping pipelines
- [ ] Build passes

---

## T6 — Propagate `halfDuplexState` to `AudioViewModel`

**File**: `TranslateCall/Features/Main/AudioViewModel.swift` (MODIFY)

### Checklist

- [ ] Add `@Published private(set) var halfDuplexState: HalfDuplexState = .listening`
- [ ] In `bindCoordinator()`, add: `coordinator.$halfDuplexState.assign(to: &$halfDuplexState)`
- [ ] Verify the convenience init (for tests/previews) initialises `halfDuplexState` correctly (default `.listening` from coordinator's initial state — already correct)
- [ ] Build passes

---

## T7 — Update `StatusBadgeView` for half-duplex states

**Files**: `TranslateCall/Features/Main/StatusBadgeView.swift`, `TranslateCall/Features/ContentView.swift` (MODIFY)

### Checklist

**StatusBadgeView.swift**:
- [ ] Replace `var isSpeaking: Bool = false` with `var halfDuplexState: HalfDuplexState = .listening`
- [ ] Update `var indicatorColor: Color` (computed from `halfDuplexState`):
  - Not capturing → `.secondary`
  - `.listening` + `isSpeechActive` → `.orange`
  - `.listening` → `.green`
  - `.speaking` → `.red`
  - `.transitioning` → `.yellow`
- [ ] Update mic icon (in HStack) to reflect state:
  - `.speaking` → `Image(systemName: "mic.slash")`
  - `.transitioning` → `Image(systemName: "clock")`
  - `.listening` → existing mic icon (no change)
- [ ] Update label text: `.speaking` → "Speaking", `.transitioning` → "Transitioning…", `.listening` → existing logic
- [ ] Update preview with `.speaking` and `.transitioning` cases

**ContentView.swift**:
- [ ] Replace `isSpeaking: viewModel.isSpeaking` with `halfDuplexState: viewModel.halfDuplexState` in `StatusBadgeView` call
- [ ] Build passes

---

## T8 — Unit tests for `HalfDuplexManager`

**Files**:
- `TranslateCallTests/HalfDuplexManagerTests.swift` (CREATE)
- `TranslateCallTests/Mocks/MockHalfDuplexCoordinator.swift` (CREATE)

### Checklist

**MockHalfDuplexCoordinator.swift**:
- [ ] `@MainActor final class MockHalfDuplexCoordinator` (does NOT inherit AudioCoordinator)
- [ ] Has `@Published var isOutgoingSpeaking: Bool = false`
- [ ] Has `@Published var isIncomingSpeaking: Bool = false`
- [ ] Tracks `suppressOutgoingCaptureCalls: [Bool]` and `suppressIncomingPipelineCalls: [Bool]`
- [ ] Methods: `func suppressOutgoingCapture(_ suppress: Bool)`, `func suppressIncomingPipeline(_ suppress: Bool)` appending to tracking arrays

> **Note**: `HalfDuplexManager` holds `weak var coordinator: AudioCoordinator?`. For the mock to work, either:
> - (a) Extract a `HalfDuplexCoordinatorProtocol` that both `AudioCoordinator` and `MockHalfDuplexCoordinator` conform to, or
> - (b) Make `HalfDuplexManager` generic over a coordinator protocol.
>
> **Preferred for simplicity**: Option (a) — define `protocol HalfDuplexCoordinating: AnyObject` with the 4 required members (`isOutgoingSpeaking`, `isIncomingSpeaking`, `suppressOutgoingCapture`, `suppressIncomingPipeline`) and make `AudioCoordinator: HalfDuplexCoordinating`.

**HalfDuplexManagerTests.swift**:
- [ ] `@Suite("HalfDuplexManager", .serialized) @MainActor`
- [ ] All tests use `transitionDelay: .milliseconds(50)` for speed

Test cases:
- [ ] `T1_initialStateIsListening` — `state == .listening` at init
- [ ] `T2_incomingSpeakingTransitionsToSpeaking` — set `incoming = true`, assert `state == .speaking`
- [ ] `T3_outgoingSpeakingTransitionsToSpeaking` — set `outgoing = true`, assert `state == .speaking`
- [ ] `T4_incomingSpeakingMutesMic` — verify `suppressOutgoingCapture(true)` called
- [ ] `T5_outgoingSpeakingBlocksLoopback` — verify `suppressIncomingPipeline(true)` called
- [ ] `T6_bothStopTransitionsToListeningAfterDelay` — set both false, `try await Task.sleep(for: .milliseconds(100))`, assert `.listening`
- [ ] `T7_newSpeakingCancelsTransitionBuffer` — set both false → immediately set incoming=true → wait 100ms, assert `.speaking` not `.listening`
- [ ] `T8_deactivateLiftsSuppression` — set incoming=true (state=.speaking), call `deactivate()`, verify `suppressOutgoingCapture(false)` called and state==.listening
- [ ] All 8 tests pass

---

## T9 — End-to-end smoke + commit

### Checklist

- [ ] Run full test suite: `xcodebuild test ... CODE_SIGN_IDENTITY="-"` — `** TEST SUCCEEDED **` (ignoring pre-existing flaky Silero/LanguagePair failures)
- [ ] Manual smoke: launch app, verify green badge when idle, badge changes color when sessions active
- [ ] `git add` all changed files
- [ ] `git commit` with message: `"Implement F4.2 — HalfDuplexManager + suppression + UI (M4)"`
- [ ] Update ROADMAP.md: mark F4.2 as COMPLETED
- [ ] Update memory/MEMORY.md with F4.2 key decisions

---

## Implementation Notes

### Re: `HalfDuplexCoordinatorProtocol`

To avoid `HalfDuplexManager` having a hard `AudioCoordinator` dependency (which would break unit tests), extract:

```swift
// In HalfDuplexManager.swift

@MainActor
protocol HalfDuplexCoordinating: AnyObject {
    var isOutgoingSpeaking: Bool { get }
    var isIncomingSpeaking: Bool { get }
    // For Combine binding:
    var isOutgoingSpeakingPublisher: AnyPublisher<Bool, Never> { get }
    var isIncomingSpeakingPublisher: AnyPublisher<Bool, Never> { get }
    func suppressOutgoingCapture(_ suppress: Bool)
    func suppressIncomingPipeline(_ suppress: Bool)
}

extension AudioCoordinator: HalfDuplexCoordinating {
    var isOutgoingSpeakingPublisher: AnyPublisher<Bool, Never> { $isOutgoingSpeaking.eraseToAnyPublisher() }
    var isIncomingSpeakingPublisher: AnyPublisher<Bool, Never> { $isIncomingSpeaking.eraseToAnyPublisher() }
}
```

`HalfDuplexManager.coordinator` becomes `weak var coordinator: (any HalfDuplexCoordinating)?`.

### Re: `transitionDelay` in `AudioCoordinator.init`

Add `transitionDelay: Duration = .milliseconds(300)` to `AudioCoordinator.init`. Pass through to `HalfDuplexManager.init`. `AppContainer` uses the default. `AudioCoordinatorTests` can pass a shorter delay if needed (but current tests don't exercise the buffer timer — that's `HalfDuplexManagerTests`' job).

---

*End of F4.2 Tasks — Gate 3 Review Pending*
