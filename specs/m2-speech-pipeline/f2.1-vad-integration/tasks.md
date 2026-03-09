# F2.1: VAD Integration — Tasks

**Feature**: Voice Activity Detection Integration
**Milestone**: M2 — Speech Pipeline
**Status**: DRAFT — awaiting Gate 3 review
**Date**: 2026-03-07
**Prerequisites**: design.md (Gate 2 approved)

---

## Dependency Order

```
T1 (types) ──▶ T2 (EnergyVAD) ──▶ T4 (factory) ──▶ T6 (ViewModel) ──▶ T7 (tests)
           ──▶ T3 (SileroVAD) ──▶ T4
                    └── T5 (history buffer) [part of T3]
```

All tasks follow TDD: write failing test → implement → green → refactor.

---

## T1 — Define shared types: `SpeechSegment`, `VADConfiguration`, `VADService` protocol

**Maps to**: REQ-VAD-01, REQ-VAD-03, REQ-VAD-04, REQ-NFR-09
**File**: `TranslateCall/Core/VAD/VADService.swift`
**Depends on**: nothing

### What to implement

1. `SpeechSegment` struct:
   ```swift
   struct SpeechSegment: Sendable {
       let audio: AVAudioPCMBuffer   // 16kHz mono Float32
       let capturedAt: Date
   }
   ```

2. `VADEngine` enum: `.silero` / `.energy`

3. `VADConfiguration` struct with all fields from design §3.2, including `fluidVadConfig` and `fluidSegmentationConfig` computed properties (marked `internal`).

4. `VADService` protocol:
   ```swift
   protocol VADService: Actor {
       nonisolated var speechSegments: AsyncStream<SpeechSegment> { get }
       nonisolated var vadStateEvents: AsyncStream<Bool> { get }
       nonisolated var engine: VADEngine { get }
       func activate(stream: AsyncStream<AVAudioPCMBuffer>) async throws
       func deactivate() async
   }
   ```

### Test (RED first)
- `testVADConfigurationDefaults()` — verify default values match spec
- `testVADConfigurationFluidMapping()` — verify `fluidVadConfig.defaultThreshold == 0.85`

### Done when
- File compiles with `-strict-concurrency=complete`, zero warnings
- Tests green

---

## T2 — Implement `EnergyVADService`

**Maps to**: REQ-VAD-20, REQ-VAD-21, REQ-VAD-22, REQ-VAD-23, REQ-NFR-09, REQ-NFR-10
**File**: `TranslateCall/Core/VAD/EnergyVADService.swift`
**Depends on**: T1

### What to implement

1. `actor EnergyVADService: VADService` with:
   - `nonisolated let speechSegments`, `vadStateEvents`, `engine = .energy`
   - `activate(stream:)` — spawns `processingTask`
   - `deactivate()` — cancels task, calls `flush()`

2. Per-buffer processing:
   - Extract `[Float]` from `AVAudioPCMBuffer` via `floatChannelData?[0]`
   - Compute RMS with `vDSP_measqv`, convert to dBFS: `10 * log10f(rms)`
   - State machine: `.silence` → `.speaking` when dBFS > threshold for ≥ `minSpeechDuration` samples
   - `.speaking` → `.silence` when dBFS ≤ threshold for ≥ `minSilenceDuration` samples

3. On speech end: call `yieldUtterance()` — wraps `utteranceBuffer: [Float]` into `AVAudioPCMBuffer` via `makePCMBuffer(from:)` helper, yields `SpeechSegment`.

4. Max duration guard: if `utteranceBuffer` exceeds `maxSpeechDuration` samples, force-yield and reset.

5. `vadStateEvents` — yield `true` on speech start, `false` on speech end.

### Tests (RED first)
- `testEnergyVADIgnoresSilence()` — feed 3s of silence buffers (zero samples), assert 0 segments (AC-04)
- `testEnergyVADDetectsSpeechStart()` — feed synthetic sine wave above threshold, assert `isSpeechActive` true within 512ms (AC-03)
- `testEnergyVADYieldsSegment()` — speak then silence, assert 1 segment with audio ≥ minSpeechDuration
- `testEnergyVADMaxDuration()` — feed continuous speech > 14s, assert forced segment emitted (AC-08)

### Done when
- `EnergyVADService` conforms to `VADService` with zero warnings
- All tests green

---

## T3 — Implement `SileroVADService` (with pre-speech history buffer)

**Maps to**: REQ-VAD-10 through REQ-VAD-16, REQ-NFR-01, REQ-NFR-07, REQ-NFR-09, AC-01, AC-02
**File**: `TranslateCall/Core/VAD/SileroVADService.swift`
**Depends on**: T1

### What to implement

1. `actor SileroVADService: VADService` — full init as per design §4.1.

2. **History buffer** (design §11):
   ```swift
   // Circular buffer storing last N samples before current chunk
   private var historyBuffer: [Float] = []
   private let historyCapacity: Int  // speechPadding samples + 1 chunk = ~5700
   ```
   After each call to `appendBuffer`, append incoming samples to `historyBuffer`; trim to `historyCapacity` from the front.

3. **On `speechStart`**:
   - Determine pre-context length from `event.sampleIndex` (how many samples back from `processedSamples`)
   - Prepend the tail of `historyBuffer` (up to `speechPadding` samples) to `utteranceBuffer`
   - Begin accumulating current chunk into `utteranceBuffer`
   - Yield `true` to `vadStateEvents`

4. **On `speechEnd`**:
   - Call `yieldUtterance()` — wraps `utteranceBuffer` into `AVAudioPCMBuffer`
   - Reset `utteranceBuffer`, `utteranceStartDate`
   - Yield `false` to `vadStateEvents`

5. **Mid-speech buffering**:
   - `sampleAccumulator` is drained chunk-by-chunk (4096 at a time)
   - When `vadStreamState.triggered`, each processed chunk is also appended to `utteranceBuffer`
   - Max duration guard: if `utteranceBuffer.count >= maxSpeechSamples`, call `yieldUtterance()` and reset `vadStreamState`

6. `makePCMBuffer(from:)` — shared helper (can be in a file-private extension or protocol extension on `VADService`).

### Tests (RED first)
- `testSileroVADLoadsModel()` — assert `SileroVADService` init succeeds (requires model download; skip in CI if offline) (AC-01 prerequisite)
- `testSileroVADDetectsSpeech()` — feed real 16kHz sine burst, assert ≥ 1 segment (AC-01)
- `testSileroVADIgnoresSilence()` — feed 3s zeros, assert 0 segments (AC-02)
- `testSileroVADSegmentDuration()` — feed 1s speech + 1s silence, assert segment duration ≈ 1s ± 300ms (AC-05)
- `testSileroVADHistoryBuffer()` — assert `utteranceBuffer` starts before `speechStart` chunk (pre-context present)
- `testSileroVADPerformance()` — measure time for 1 chunk, assert < 20ms (AC-07)
- `testSileroVADMaxDuration()` — feed 15s continuous speech, assert forced emit (AC-08)

### Done when
- Silero VAD processes real audio correctly end-to-end
- History buffer test passes (first chunk of utterance contains pre-context samples)
- Performance test < 20ms on device
- Zero Swift 6 warnings

---

## T4 — Implement `VADServiceFactory`

**Maps to**: REQ-VAD-30, REQ-VAD-31, AC-09
**File**: `TranslateCall/Core/VAD/VADServiceFactory.swift`
**Depends on**: T2, T3

### What to implement

```swift
@MainActor
final class VADServiceFactory: ObservableObject {
    @Published private(set) var activeEngine: VADEngine
    @Published private(set) var sileroModelAvailable: Bool
    private(set) var service: any VADService
}
```

1. `init(config:)` — synchronously creates `EnergyVADService`, sets it as `service`, then fires off `Task { await tryLoadSilero() }`.

2. `tryLoadSilero(config:)` — `async`, tries `SileroVADService(config:)`, on success replaces `service` + updates `activeEngine` / `sileroModelAvailable`. On failure, stays on energy.

3. `preferredEngine` override: if caller sets `.energy` explicitly, skip Silero init even if model is available.

### Tests (RED first)
- `testFactoryDefaultsToEnergy()` — fresh factory before Silero loads, assert `activeEngine == .energy`
- `testFactoryEngineSelection()` — factory with `preferredEngine = .energy`, assert stays energy even after Silero available (AC-09)
- `testFactoryPromotesToSilero()` — inject pre-loaded `SileroVADService`, assert `activeEngine == .silero`

### Done when
- Factory compiles `@MainActor` cleanly
- Tests green

---

## T5 — Wire VAD into `AudioViewModel`

**Maps to**: REQ-VAD-40, REQ-VAD-41, REQ-VAD-50, REQ-VAD-51, REQ-VAD-52
**File**: `TranslateCall/Features/Main/AudioViewModel.swift` (modify existing)
**Depends on**: T4

### What to implement

1. Add to `AudioViewModel`:
   ```swift
   @Published var isSpeechActive: Bool = false
   private let vadFactory: VADServiceFactory
   private var vadStateTask: Task<Void, Never>?
   ```

2. In `startCapture()` (existing method): after `audioManager.startCapture()`, call:
   ```swift
   try await vadFactory.service.activate(stream: audioManager.audioStream16kHz)
   observeVADState(vadFactory.service)
   ```

3. In `stopCapture()` (existing method): call `await vadFactory.service.deactivate()`, cancel `vadStateTask`.

4. `observeVADState(_:)` — spawns `@MainActor` task that iterates `service.vadStateEvents` and assigns to `self.isSpeechActive`.

5. Update `ContentView` / status indicator to reflect `isSpeechActive` (green dot = listening, red = speech detected by VAD).

### Tests (RED first)
- `testViewModelVADActivatesOnStart()` — mock `VADService`, assert `activate` called after `startCapture()`
- `testViewModelVADDeactivatesOnStop()` — assert `deactivate` called after `stopCapture()`
- `testViewModelIsSpeechActiveUpdates()` — inject `vadStateEvents` with `true`, assert `isSpeechActive == true` (AC-06)

### Done when
- App builds and runs
- Tapping Start begins VAD; status badge reflects speech detection in real time

---

## T6 — Integration test: end-to-end VAD on real audio

**Maps to**: AC-01 through AC-10 (integration level)
**File**: `TranslateCallTests/VADIntegrationTests.swift`
**Depends on**: T1–T5

### What to implement

Use a pre-recorded 10-second WAV file (Spanish speech with pauses) bundled in the test target:
- 3 utterances separated by > 750ms silences
- Verify `SileroVADService` yields exactly 3 `SpeechSegment` values
- Verify each segment audio is non-empty and ≥ 150ms
- Verify first segment starts with pre-context (history buffer test at integration level)

Mark with `@available(*, machine-only)` or a `XCTSkipUnless` condition when Silero model not present (CI safety).

### Done when
- Integration test passes locally with Silero model downloaded
- CI passes (test is skipped gracefully when model absent)
- All 10 acceptance criteria from requirements.md are covered by some test

---

## Task Summary

| Task | File(s) | Effort | Blocks |
|------|---------|--------|--------|
| T1 — Shared types + protocol | `VADService.swift` | Small | T2, T3 |
| T2 — EnergyVADService | `EnergyVADService.swift` | Medium | T4 |
| T3 — SileroVADService + history buffer | `SileroVADService.swift` | Large | T4 |
| T4 — VADServiceFactory | `VADServiceFactory.swift` | Small | T5 |
| T5 — Wire into AudioViewModel + UI | `AudioViewModel.swift`, `ContentView` | Medium | T6 |
| T6 — Integration test | `VADIntegrationTests.swift` | Medium | — |

---

*Gate 3 Review: human must approve this document before implementation begins.*
