# M9 voice-clone streaming and early end-of-turn — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In a call, the other side hears the user's cloned voice < 1.5 s (p50) after the user stops talking. Today it is ~8 s.

**Architecture:**
- **Clone streaming.** `MLXInferenceGate.runStream` relays Qwen3-TTS chunks while the caller listens and drains the model's stream to its end whatever the caller does. `QwenUtteranceSynthesizer` yields one buffer per chunk; `TTSPlaybackService` already schedules buffers as they come.
- **Short reference.** A guided recording (a shown text, ~8 s) makes the prompt short. A probe gate picks the length by ear first.
- **Early processing.** The VAD hands a **tentative** segment to STT at the first silent chunk and later **commits** or **retracts** it. A `TurnCommitter` per direction translates tentatives at once and shows/speaks them only at commit.

**Tech Stack:**
- Swift 6 (app target: default MainActor isolation, `MemberImportVisibility`), `Synchronization.Mutex`;
- mlx-audio-swift 0.1.2 (`SpeechGenerationModel.generateStream`), FluidAudio (Silero `VadManager`), WhisperKit, Speech, Apple Translation;
- SwiftUI (recording flow, Settings › Voices);
- Swift Testing, `just`, SwiftLint (strict), opengrep;
- the bench: Swift side (`TranslateCallTests/Bench/`) and `tools/bench/tcbench` (Python, uv).

**Spec:** `specs/m9-product/qwen-streaming/requirements.md` and `design.md` (APPROVED 2026-10-31, Q-1…Q-7). Research context for later work: `research-end-of-turn.md`.

## Global Constraints

- **Branches and PR:**
  - work on `feat/m9-qwen-streaming`, created from `spec/m9-qwen-streaming` (Task 0); spec and code ship in one PR;
  - never commit to `main`; `just pr` must pass before the PR;
  - execution is subagent-driven. Tasks marked **opus** need the opus model (concurrency); **sonnet** otherwise. Every phase ends at a gate (G1…G4): `just pr`-equivalent checks green and a whole-phase review before the next phase starts.
- Commits: Conventional Commits; end every message with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Xu5uL4WghYH88qL18aEUmP
  ```
- **Build settings:** `SWIFT_VERSION = 6.0`, `MACOSX_DEPLOYMENT_TARGET = 15.0`. The app target has `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: anything used off the main actor says `nonisolated`. The test target has no default isolation. New files are picked up automatically (`PBXFileSystemSynchronizedRootGroup`); never edit `project.pbxproj`.
- **Unit tests:** no audio device, no ML model, no network, no `UserDefaults.standard` (use `UserDefaults(suiteName: "test-\(UUID())")`). Time through `TestClock` (`TranslateCallTests/Support/TestClock.swift`); waiting through `waitUntil` / `AsyncGate` / `LockedArray` (`Support/AsyncTestHelpers.swift`, `Support/TTSFakes.swift`). No fixed sleeps.
- **Recipes:** `just test-only <SuiteStructName> […]`; `just test`; `just lint`; `just scan`; `just test-bench-tools`; `just bench pr <profile>`; `just pr`.
- **SwiftLint strict** (app target): lines ≤ 120; function bodies ≤ 50; type bodies ≤ 250; **files ≤ 400**; cyclomatic complexity ≤ 10; identifiers ≥ 3 chars; tuples ≤ 2 members; `multiple_closures_with_trailing_closure` (label every closure when a call takes two); sorted imports.
- **Line budgets today:**
  - `AudioCoordinator+Pipeline.swift` 398/400 — Task 11 moves code out before anything is added;
  - `TTSPlaybackService.swift` 394/400 — Task 4 moves the "One attempt" extension out first.
- **Values pinned by the spec (copy exactly):**
  - `streamingInterval = 0.32`; first-chunk limit **3 s** measured from the call, gate wait included; gate wait **2 s**; utterance watchdog **30 s** (unchanged); `inferenceTimeoutSeconds = 10` stays for the preview only;
  - `longReferenceSeconds = 12`; `freeMaxSeconds = 30`; `guidedMaxSeconds = 15`; guided target **8 s** until gate P-1 says otherwise;
  - warm-up only if cold first chunk > **1.5×** warm;
  - default pause **0.6 s**; **0.4 s** only through Task 16; range 0.4–1.2 s unchanged;
  - Energy VAD tentative after **0.2 s** of silence.
- **Release only for latency:** Debug Qwen runs below real time. Every latency number comes from the bench (Release since `db6c038`) or the probe recipe (Release).
- **Volume access:** if a build fails with "Operation not permitted" under `/Volumes/SpBarberDev`, stop and ask the user (macOS TCC). Do not work around it.
- Do not touch `/Users/spbarber/Desarrollo/poc-namo-turn` (Namo PoC, separate).

## Review Focus

- **Stop mid-sentence, then speak again at once.** The stopped generation keeps the gate for up to ~5–8 s. The next sentence must go straight to AVSpeech (no 2 s wait), and the breaker must not open. Pinned in Task 4 (`abandonedGateFallsBackWithoutBreaker`).
- **Voice cloning turned off, or the session stopped, while an abandoned stream drains.** `unload()` waits for the drain; no client freed under MLX, no crash. Pinned in Task 2 (`unloadWaitsForStreamDrain`).
- **The user hesitates twice inside one sentence** (tentative → retract → tentative → retract → tentative → commit). One sentence is shown and spoken, with the whole text, once. Pinned in Task 14 (`twoHesitationsOneSentence`).
- **Noise closes a tentative and STT returns nothing.** Commit speaks nothing, and the next sentence is not blocked behind it. Pinned in Task 13 (`noResultStillYieldsEmpty`) and Task 14 (`emptyCommitDoesNotBlock`).
- **Stop or pause while a tentative's translation is held.** Nothing from it is shown or spoken after stop; a paused commit is shown, not spoken (today's rule). Pinned in Task 14 (`stopDropsHeld`, `pausedCommitShownNotSpoken`).

## Decisions made while planning (spec deviations are marked ⚠)

Replayed on a throwaway clone of `spec/m9-qwen-streaming` at f069e24 + `db6c038` (see Replay notes).

| # | Point | Choice |
|---|-------|--------|
| P1 ⚠ | design §5 `statsObserver` on the synthesizer for the bench | Dropped. The bench already records every buffer's schedule instant (`BenchOutput`, `AudioCollector`), so it computes gaps itself with the same `StreamGapTracker` (Task 3). The synthesizer only logs. The production factory is not touched. |
| P2 ⚠ | design §3 signature | `runStream(wait:firstElement:isFirst:work:)`: every closure labelled (`multiple_closures_with_trailing_closure`). `isFirst` exists because `.info` must not stop the first-chunk timer (design §4). |
| P3 | Gate internals from another file | `acquire(waitLimit:)`, `release()` and `clock` lose `private`. New `var currentStream: (any GateStreamLink)?`, cleared in `release()`. `isHeldByAbandonedStream` = `currentStream` present and detached. That is a synchronous read of the link's `Mutex`, so there is no async flag to race. |
| P4 ⚠ | design §10.3 "engines untouched apart from passing two fields" | Engines must also yield a result for **every** segment (empty text when today they yield nothing: low confidence, empty, error). Otherwise the committer waits forever for a tentative's text. Downstream already ignores empty text. |
| P5 ⚠ | design §2 / §7.3 "the recorder's 30 s auto-stop" | It lives in `VoiceProfileManager.startElapsedTimer` (`VoiceProfileManager.swift:221-235`) and the labels in `VoiceRecordingView.swift:17,22,30`. The mode goes to the manager; the recorder only grades. |
| P6 | Silero tentative trigger | Use FluidAudio's own state: `VadStreamState.tempEndSample` going nil → non-nil while `triggered` = tentative; back to nil while still `triggered` = retract (`VadManager+Streaming.swift:57-72`). `.speechEnd` = commit. That keeps FluidAudio's hysteresis (negative threshold = threshold − 0.15). The logic is a pure `TentativeTracker`, so it is unit-tested without CoreML. |
| P7 | Committer output | `Deliver = (text, Task<String, Error>)`. The transcript entry and the "translating" state appear at commit, as today for a final segment. A tentative's translation started early is simply already done. Apple Translation queues requests in its bridge (`AppleTranslationService.swift:5`), so overlapping translations are safe. |
| P8 | `TTSPlaybackService.swift` is 394/400 | Task 4 first moves `extension TTSPlaybackService` "One attempt" (`runAttempt`, `consume`, `conclude`, `drainPlayback`, `recordMetrics`) to `TTSPlaybackService+Attempt.swift`. Pure move; the private members it needs become `fileprivate(set)`/internal as the compiler asks. |
| P9 | REQ-QS-07a "does not count toward the breaker" | `nonisolated protocol TTSAttemptError: Error { var countsTowardBreaker: Bool { get } }` in `UtteranceSynthesizer.swift`. `QwenCloneError` conforms (false only for `.gateBusyAbandoned`). `consume` records it, `perform` skips `recordPrimaryFailure()` when false. The fallback still runs. |
| P10 | Tracer with tentatives | `PipelineTracer` gets `segmentRetracted(capturedAt:)` (emits new stage `.retracted` and forgets the utterance) and `segmentCommitted(capturedAt:)` (stage `.committed`). `vadEnd` stays the tentative's emission. `tcbench` ignores retracted seqs when matching clips (so cut rate and WER are unaffected) and reports the retract share and speech end → `committed`. |
| P11 | How the probe runs in Release | New recipe `just qwen-probe`, script `tools/scripts/qwen-probe.sh`. It reuses the bench's Release `build-for-testing` invocation (`tools/scripts/bench.sh:95`) with `-only-testing:TranslateCallTests/QwenCloneProbeTests` and `TEST_RUNNER_TC_QWEN_PROBE=1`. |
| P12 | "Record short sample" makes the new voice active (REQ-QS-15) | `VoiceProfileManager.saveProfile(name:transcript:result:makeActive:)` with `makeActive: Bool = false`; the guided flow from the hint passes `true`. |
| P13 | `GatedQwenInferrer.synthesizeStream` is sync but the manager is an actor | It returns a stream whose task awaits `manager.synthesizeStream(...)` and relays it; `onTermination` cancels that task (the gate keeps draining). Replayed. |
| P14 | Clone stats in the session log | One `logger.info` per sentence in `QwenUtteranceSynthesizer`, numbers `.public`: `firstChunkMs`, `totalMs`, `audioSeconds`, `tokensPerSecond`, `gapCount`, `gapMs`. No text. |
| P15 | Where `TurnCommitter` lives | `@MainActor final class` (app default), one per direction, owned by `AudioCoordinator` (`outgoingCommitter`, `incomingCommitter`), created in each `start…Pipeline`, `cancelAll()` in each teardown. |

## File Structure

```
TranslateCall/
  Core/VoiceCloning/MLXInferenceGate.swift        MOD T1 (acquire/release/clock internal, currentStream)
  Core/VoiceCloning/MLXInferenceGate+Stream.swift NEW T1 (GateStreamLink, StreamRelay, runStream, isHeldByAbandonedStream)
  Core/VoiceCloning/QwenCloneInferring.swift      MOD T2 (QwenStreamEvent, synthesizeStream)
  Core/VoiceCloning/QwenCloneConfiguration.swift  MOD T2 (streamingInterval, firstChunkTimeoutSeconds, gateBusyAbandoned);
                                                      T7 (reference-length constants)
  Core/VoiceCloning/QwenCloneClient.swift         MOD T2
  Core/VoiceCloning/QwenCloneModelManager.swift   MOD T2 (synthesizeStream, GatedQwenInferrer); T10 (warmUp, conditional)
  Core/VoiceCloning/QwenUtteranceSynthesizer.swift MOD T3
  Core/TTS/StreamGapTracker.swift                 NEW T3
  Core/TTS/UtteranceSynthesizer.swift             MOD T4 (TTSAttemptError)
  Core/TTS/TTSPlaybackService.swift               MOD T4 (move out; breaker exemption)
  Core/TTS/TTSPlaybackService+Attempt.swift       NEW T4 (moved code)
  Core/VoiceCloning/GuidedReadingTexts.swift      NEW T7
  Core/VoiceCloning/VoiceRecordingMode.swift      NEW T8 (RecordingMode, VoiceQualityRules)
  Core/VoiceCloning/VoiceProfileRecorder.swift    MOD T8 (grade by mode, silence trim)
  Core/VoiceCloning/VoiceProfileManager.swift     MOD T8 (mode, auto-stop, makeActive)
  Features/VoiceCloning/VoiceRecordingView.swift, VoiceTranscriptView.swift, GuidedRecordingChoiceView.swift (NEW)  T9
  Features/Settings/VoiceProfileRow.swift, VoicesSettingsView.swift  MOD T9 (long-voice hint)
  Core/Audio/AudioCoordinator+Translation.swift   NEW T11 (moved handlers, split in halves)
  Core/Audio/AudioCoordinator+Pipeline.swift      MOD T11 (move out), T14 (wiring)
  Core/VAD/VADService.swift                       MOD T12 (SpeechSegment.id/kind, SegmentKind, SegmentBoundary, boundaryEvents)
  Core/VAD/TentativeTracker.swift                 NEW T12
  Core/VAD/SileroVADService.swift, EnergyVADService.swift  MOD T12
  Core/Trace/TracingDecorators.swift              MOD T12 (boundaryEvents passthrough), T15 (tracer calls)
  Core/STT/SpeechRecognizerService.swift          MOD T13 (TranscriptionResult.segmentID/kind)
  Core/STT/AppleSpeechService.swift, ParakeetSpeechService.swift, WhisperSpeechService.swift  MOD T13
  Core/Audio/TurnCommitter.swift                  NEW T14
  Core/Audio/AudioCoordinator.swift               MOD T14 (committer properties)
  Core/Trace/TraceEvent.swift, PipelineTracer.swift  MOD T15 (.committed, .retracted)
  Core/Audio/ConversationSettings.swift           MOD T16 (conditional)
TranslateCallTests/
  MLXInferenceGateStreamTests T1; QwenCloneModelManagerTests MOD T2; Mocks/MockQwenCloneInferrer MOD T2;
  QwenUtteranceSynthesizerTests MOD T3; StreamGapTrackerTests T3; TTSPlaybackFallbackTests MOD T4;
  Integration/QwenCloneProbeTests (commit + extend) T6; GuidedReadingTextsTests T7; VoiceRecordingModeTests T8;
  TentativeTrackerTests, EnergyVADTentativeTests T12; Mocks/MockVADService MOD T12; STTSegmentTaggingTests T13;
  TurnCommitterTests, AudioCoordinatorEarlyProcessingTests T14; PipelineTracerTests MOD T15;
  Bench/BenchRunner.swift (AudioCollector gaps) T5
tools/bench/tcbench/analyze.py, report.py (+ tests)  MOD T5, T15
tools/scripts/qwen-probe.sh NEW T6; justfile MOD T6
specs/m9-product/backlog.md, docs/ARCHITECTURE.md  MOD T17
```

**Dependency order:** T0 → T1 → T2 → T3 → T4 → T5 → **G1** → T6 → **P-1 (user)** → T7 → T8 → T9 → T10? → **G2** → T11 → T12 → T13 → T14 → T15 → **G3** → T16? → **G4** → T17 → T18.

**Executor per task:** **opus:** T1, T3, T12, T14, and the final whole-branch review. **sonnet:** T0, T2, T4–T11, T13, T15–T17.

| Phase | Tasks | Gate |
|---|---|---|
| 1. Clone streaming | T0–T5 | G1 |
| 2. Short reference | T6, P-1, T7–T10 | G2 |
| 3. Early processing | T11–T15 | G3 |
| 4. Shorter pause + acceptance | T16, G4, T17, T18 | acceptance |

---

## Phase 1 — Clone streaming

### Task 0: Branch (sonnet)

- [x] **Step 1:** In the main checkout: `git switch spec/m9-qwen-streaming && git branch -f feat/m9-qwen-streaming && git switch feat/m9-qwen-streaming`. The old `feat/m9-qwen-streaming` is `db6c038` on the old main, with no other commits; `-f` is safe.
- [x] **Step 2:** `git cherry-pick db6c038` (bench in Release). Expected: clean (replayed).
- [x] **Step 3:** `just test-bench-tools` → green; `just build` → succeeded.
- [x] **Step 4:** Leave `TranslateCallTests/Integration/QwenCloneProbeTests.swift` untracked; Task 6 commits it.

---

### Task 1: The gate, streaming (opus)

**Files:**
- Modify: `TranslateCall/Core/VoiceCloning/MLXInferenceGate.swift` (`clock`, `acquire`, `release` internal; `currentStream`)
- Create: `TranslateCall/Core/VoiceCloning/MLXInferenceGate+Stream.swift`
- Test: `TranslateCallTests/MLXInferenceGateStreamTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated protocol GateStreamLink: AnyObject, Sendable { var isAttached: Bool { get } }`
  - `nonisolated final class StreamRelay<Element: Sendable>: GateStreamLink`: `init(_ continuation: AsyncThrowingStream<Element, Error>.Continuation)`, `func yield(_ element: Element, first: Bool)`, `func end(throwing error: Error? = nil, onlyBeforeFirst: Bool = false)` (once; later calls do nothing), `func detach()`
  - `extension MLXInferenceGate`:
    - `var isHeldByAbandonedStream: Bool`
    - `nonisolated func runStream<Element: Sendable>(wait: Duration = .seconds(2), firstElement: Duration, isFirst: @escaping @Sendable (Element) -> Bool = { _ in true }, work: @escaping @Sendable () -> AsyncThrowingStream<Element, Error>) -> AsyncThrowingStream<Element, Error>`
  - In `MLXInferenceGate`: `var currentStream: (any GateStreamLink)?`, set by the pump's start, cleared in `release()`.

Behaviour (design §3, P2, P3):
- the first-element timer starts at the call (gate wait included); it fails the relay with `QwenCloneError.inferenceTimeout` only if no `isFirst` element was relayed;
- the starter task acquires (`gateBusy` after `wait`; cancelled with the relay's `onTermination`);
- if the relay is already detached when the gate is handed over: release at once, never call `work`;
- otherwise set `currentStream`, start a **detached** pump that iterates `work()` to its end, yields while attached, then ends the relay (if still attached), cancels the timer, `release()`s.

- [x] **Step 1: Write the failing tests** (TestClock, `AsyncGate`, `LockedArray`; inner streams from `AsyncThrowingStream.makeStream`):
  - `relaysInOrder`: inner yields 1, 2, 3, finishes → caller gets `[1, 2, 3]`; afterwards `!(await gate.isBusy)`.
  - `abandonedKeepsGateUntilInnerEnds`: caller task reads 1, is cancelled → `await gate.isHeldByAbandonedStream`, `await gate.isBusy`; open the inner's gate, inner yields 2 and finishes → `waitUntil { !(await gate.isBusy) }` and `!(await gate.isHeldByAbandonedStream)`; the caller never saw 2.
  - `firstElementTimeoutCountsGateWait`: gate held by a one-shot `run` that waits on an `AsyncGate`; `runStream(wait: .seconds(2), firstElement: .seconds(3))` queued; `clock.advance(by: .seconds(2))` → `QwenCloneError.gateBusy` (the wait limit fires first). Second case, gate free: inner yields nothing; advance 3 s → `.inferenceTimeout`; `await gate.isBusy` stays true until the inner finishes.
  - `infoDoesNotStopTimer`: `isFirst: { $0 > 0 }`; inner yields `0`, then nothing; advance 3 s → `.inferenceTimeout`.
  - `innerErrorRelayedAndReleased`: inner throws `FakeSynthError.boom` → caller gets it; gate idle.
  - `waitUntilIdleWaitsForPump`: caller cancelled mid-stream; `waitUntilIdle()` returns only after the inner finishes (check with a flag set before `innerCont.finish()`).
  - `oneShotAndStreamExclude`: while a stream runs (inner held), a one-shot `run(wait: .seconds(2), inference: .seconds(10))` waits (`gate.waitingCount == 1`); it runs once the inner finishes. `ConcurrencyProbe` peak == 1.
  - `cancelWhileQueuedNeverStarts`: gate busy; stream queued, its caller cancelled → `work` never called (counter 0), `waitingCount` back to 0.
- [x] **Step 2:** `just test-only MLXInferenceGateStreamTests` → FAIL (no `runStream`).
- [x] **Step 3:** Implement as in Interfaces. Replay has a working version (Replay notes): copy its shape, not its comments.
- [x] **Step 4:** `just test-only MLXInferenceGateStreamTests MLXInferenceGateTests` → PASS; run the new suite 20 times (`for i in $(seq 20); do just test-only MLXInferenceGateStreamTests || break; done`) → no flake.
- [x] **Step 5:** `just lint`; commit `feat(tts): stream Qwen inference through the MLX gate (REQ-QS-06)`.

Reviewer: no `Task {}` inherits a caller's cancellation for the pump (it must be `Task.detached`); `release()` runs exactly once per acquire on every path (detached-before-start, normal end, inner error).

---

### Task 2: Streaming inferrer, client and manager (sonnet)

**Files:**
- Modify: `Core/VoiceCloning/QwenCloneInferring.swift`, `QwenCloneConfiguration.swift`, `QwenCloneClient.swift`, `QwenCloneModelManager.swift`
- Modify: `TranslateCallTests/Mocks/MockQwenCloneInferrer.swift`
- Test: `TranslateCallTests/QwenCloneModelManagerTests.swift`

**Interfaces:**
- Consumes: `runStream(wait:firstElement:isFirst:work:)`, `isHeldByAbandonedStream` (Task 1).
- Produces:
  - `nonisolated enum QwenStreamEvent: Sendable, Equatable { case audio([Float]); case info(tokens: Int, tokensPerSecond: Double) }`
  - `QwenCloneInferring.synthesizeStream(text: String, referenceAudio: [Float], referenceTranscript: String, language: String) -> AsyncThrowingStream<QwenStreamEvent, Error>` (synchronous; `synthesize` stays for the preview)
  - `QwenCloneConfiguration`: `var streamingInterval: Double = 0.32`, `var firstChunkTimeoutSeconds: Double = 3`
  - `QwenCloneError.gateBusyAbandoned` (description "The voice clone model is finishing a previous sentence.")
  - `QwenCloneModelManager.synthesizeStream(text:referenceAudio:referenceTranscript:language:) async -> AsyncThrowingStream<QwenStreamEvent, Error>`: not `.ready` → a stream failing with `.modelNotReady`; `await gate.isHeldByAbandonedStream` → failing with `.gateBusyAbandoned`; else `gate.runStream(firstElement: .seconds(config.firstChunkTimeoutSeconds), isFirst: { if case .audio = $0 { true } else { false } }, work: { inferrer.synthesizeStream(...) })`
  - `GatedQwenInferrer.synthesizeStream` relays the manager's stream (P13).
  - `MockQwenCloneInferrer`: `func setStubStream(_ events: [QwenStreamEvent], holdBefore: Int? = nil, failAfter: Int? = nil)` and a `let gate = AsyncGate()` for `holdBefore`. Without a stub stream, `synthesizeStream` yields `.audio(stubSamples)` once (so old tests keep their meaning). It counts `streamCallCount`.

`QwenCloneClient.synthesizeStream`: the same `GenerateParameters` as `synthesize`; `model.generateStream(text:voice:refAudio:refText:language:generationParameters:streamingInterval: config.streamingInterval)`; `.audio(chunk)` → `chunk.asArray(Float.self)`, dropped when empty; `.info(i)` → `.info(tokens: i.generationTokenCount, tokensPerSecond: i.tokensPerSecond)`; `.token` ignored. A relay task, cancelled on termination (the gate drains).

- [x] **Step 1: Failing tests** in `QwenCloneModelManagerTests`, using the manager's injectable loader and a private `MLXInferenceGate(clock: TestClock())` (the init already takes `gate:`):
  - `streamNotReady`: idle manager → first `next()` throws `QwenCloneError.modelNotReady`.
  - `streamThroughGate`: ready manager with a mock stub stream `[.audio([0.1]), .audio([0.2]), .info(tokens: 4, tokensPerSecond: 20)]` → collected events equal that list.
  - `abandonedFailsFast`: mock held before index 1; first caller reads one event and is cancelled; a second `synthesizeStream` → throws `.gateBusyAbandoned` immediately (no clock advance); open the mock gate → `waitUntil { !(await gate.isBusy) }`.
  - `unloadWaitsForStreamDrain`: as above, cancel the caller, then `await manager.unload()` in a task → it has not returned while the mock is held; open → returns; `manager.state == .idle`.
- [x] **Step 2:** `just test-only QwenCloneModelManagerTests` → FAIL.
- [x] **Step 3:** Implement per Interfaces.
- [x] **Step 4:** `just test-only QwenCloneModelManagerTests QwenUtteranceSynthesizerTests VoicePreviewServiceTests` → PASS; `just build` → succeeded (the client compiles against mlx-audio).
- [x] **Step 5:** Commit `feat(tts): streaming Qwen3-TTS inference in the client and manager (REQ-QS-02/03)`.

---

### Task 3: The synthesizer streams; gap rule and per-sentence log (opus)

**Files:**
- Create: `TranslateCall/Core/TTS/StreamGapTracker.swift`
- Modify: `TranslateCall/Core/VoiceCloning/QwenUtteranceSynthesizer.swift`
- Test: `TranslateCallTests/StreamGapTrackerTests.swift`, `TranslateCallTests/QwenUtteranceSynthesizerTests.swift`

**Interfaces:**
- Consumes: `QwenCloneInferring.synthesizeStream`, `QwenStreamEvent` (Task 2).
- Produces:
  - `nonisolated struct StreamGapTracker: Sendable` with `mutating func chunk(arrivedAt: Duration, seconds: Double)` (time since the attempt started), `var gapCount: Int`, `var gapSeconds: Double`, `var firstChunkAt: Duration?`. Rule (design §5): the first chunk sets `playEnd = t + seconds`. Each later chunk at `t`: if `t > playEnd`, then `gapCount += 1`, `gapSeconds += t − playEnd`, `playEnd = t + seconds`; else `playEnd += seconds`. Task 5 reuses it.
  - `QwenUtteranceSynthesizer.synthesize` streams: one `PCMBufferFactory.mono` buffer per `.audio`; no audio by the end → `QwenCloneError.emptyOutput`; errors pass through; `onTermination` cancels the producer. At the end (success or error after audio), one log line (P14), times from `ContinuousClock`.

- [x] **Step 1: Failing tests**:
  - `StreamGapTrackerTests.rule` (table): chunks (t s, len s) `[(0.8, 0.32), (1.0, 0.32), (1.3, 0.32)]` → 0 gaps. `[(0.8, 0.32), (1.5, 0.32)]` → 1 gap, 0.38 s. `[(0.8, 0.32), (1.5, 0.32), (1.7, 0.32)]` → 1 gap (1.7 < 1.82). Compare with `abs(a − b) < 1e-9`.
  - `QwenUtteranceSynthesizerTests.yieldsBufferPerChunk`: stub stream of three `.audio` (2400, 4800, 2400 samples) + `.info` → three 24 kHz buffers with those frame lengths, in order.
  - `emptyChunksSkipped`: `.audio([])` between two chunks → two buffers.
  - `noAudioThrowsEmpty`: only `.info` → throws `QwenCloneError.emptyOutput`.
  - `errorAfterFirstChunk`: `failAfter: 1` → one buffer, then the error (the playback service turns that into "interrupted").
  - `consumerCancelStopsYielding`: hold before index 1; cancel the collecting task → no second buffer after opening the gate; `streamCallCount == 1`.
  - Keep the existing tests (they now go through `synthesizeStream` via the mock's default).
- [x] **Step 2:** `just test-only StreamGapTrackerTests QwenUtteranceSynthesizerTests` → FAIL.
- [x] **Step 3:** Implement.
- [x] **Step 4:** Same command → PASS.
- [x] **Step 5:** Commit `feat(tts): the voice clone speaks as it is generated (REQ-QS-01/04/22)`.

---

### Task 4: Playback — first-chunk fallback and the abandoned gate (sonnet)

**Files:**
- Create: `TranslateCall/Core/TTS/TTSPlaybackService+Attempt.swift` (moved code, P8)
- Modify: `TranslateCall/Core/TTS/TTSPlaybackService.swift`, `TranslateCall/Core/TTS/UtteranceSynthesizer.swift`, `TranslateCall/Core/VoiceCloning/QwenCloneConfiguration.swift`
- Test: `TranslateCallTests/TTSPlaybackFallbackTests.swift`, `TranslateCallTests/Support/TTSFakes.swift` (`FakeSynthesizer.Script.failWith: Error?`)

**Interfaces:**
- Produces: `nonisolated protocol TTSAttemptError: Error { var countsTowardBreaker: Bool { get } }`; `extension QwenCloneError: TTSAttemptError` (`countsTowardBreaker` is `self != .gateBusyAbandoned`).

- [x] **Step 1: Move** the "One attempt" extension (`TTSPlaybackService.swift:287-394`) to the new file, unchanged. `just test-only TTSPlaybackServiceTests TTSPlaybackFallbackTests TTSPlaybackQueueTests` → PASS. Commit `refactor(tts): playback attempt in its own file`.
- [x] **Step 2: Failing tests** in `TTSPlaybackFallbackTests` (add `failWith` to `FakeSynthesizer.Script`: the error thrown instead of `FakeSynthError.boom`):
  - `abandonedGateFallsBackWithoutBreaker`: primary `.voiceClone` scripted `failAfter: 0, failWith: QwenCloneError.gateBusyAbandoned` (repeating); fallback AVSpeech. Speak 4 sentences → fallback texts are all 4; `harness.service.isBreakerOpen == false`; `.fellBack` emitted 4 times.
  - `firstChunkTimeoutFallsBack`: primary fails with `.inferenceTimeout` before audio → fallback speaks; after 3 sentences the breaker is open (timeouts still count).
- [x] **Step 3:** `just test-only TTSPlaybackFallbackTests` → FAIL.
- [x] **Step 4: Implement:** an actor property `attemptCountsTowardBreaker = true`, reset in `runAttempt` and set in `consume`'s catch from `(error as? any TTSAttemptError)?.countsTowardBreaker ?? true`. `perform` calls `recordPrimaryFailure()` only when it is true. Both files stay ≤ 400 lines.
- [x] **Step 5:** `just test-only TTSPlaybackFallbackTests TTSPlaybackServiceTests TTSPlaybackQueueTests` → PASS; `just lint`.
- [x] **Step 6:** Commit `feat(tts): an abandoned clone generation falls back at once, outside the breaker (REQ-QS-07a)`.

---

### Task 5: Bench — the clone path, gaps and reference length (sonnet)

**Files:**
- Modify: `TranslateCallTests/Bench/BenchRunner.swift` (`AudioCollector`, `makeMeta`), `TranslateCallTests/Bench/BenchModels.swift` (`RawRun.Utterance.playback`)
- Modify: `tools/bench/tcbench/analyze.py`, `tools/bench/tcbench/report.py`, `tools/bench/tests/test_analyze.py`, `test_report.py`

**Interfaces:**
- Consumes: `StreamGapTracker` (Task 3).
- Produces:
  - `RawRun.Utterance.playback: Playback?` with `struct Playback: Codable, Equatable { let gapCount: Int; let gapMs: Int }`. It is optional, so old runs still decode. `AudioCollector` fills it per attempt from its buffers' schedule instants (seconds = `frameLength / sampleRate`) through `StreamGapTracker`.
  - Meta `settings["voiceProfileSeconds"]` = the active profile's `header.durationSeconds` when the clone is the outgoing TTS (REQ-QS-20).
  - `analyze.py`: per profile/direction, `clone.firstChunkMs` p50/p90 (`ttsFirstBuffer − translated` for utterances whose engine is `voiceClone`), `clone.gapSentencesPct`, `clone.gapMsTotal`. Informative: not in `compare` verdicts.
  - `report.py`: a "Voice clone" table when present.

- [x] **Step 1: Failing Python tests**: `test_analyze.py::test_clone_playback_stats` (fixture: 4 clone utterances, one with `playback.gapCount = 2, gapMs = 300` → `gapSentencesPct == 25.0`, `gapMsTotal == 300`); `test_report.py::test_clone_table_rendered`. `test_analyze.py::test_old_runs_without_playback` still loads.
- [x] **Step 2:** `just test-bench-tools` → FAIL.
- [x] **Step 3:** Implement the Python side, then the Swift side. `BenchModelsTests` gets `decodesUtteranceWithoutPlayback` and `encodesPlayback`.
- [x] **Step 4:** `just test-bench-tools` → PASS; `just test-only BenchModelsTests BenchRunLineTests` → PASS (the run-line test skips without the bench env).
- [x] **Step 5:** Commit `feat(bench): measure the voice-clone path — gaps, first chunk, reference length (REQ-QS-20/21)`.

---

### Gate G1 (phase 1)

- [x] `just build && just check && just test` → green.
- [x] `just bench pr best` with the user's current 31 s voice (`voiceProfileSeconds ≈ 31` in meta): the outgoing TTS engine is `voiceClone` in every clone line (UI-S3 closed). Record total p50/p90, `clone.firstChunkMs`, gap %. Expected around 2.3 s total. Informative.
- [x] Whole-phase review (opus) of T1–T5.

---

## Phase 2 — Short reference

### Task 6: Probe for the reference-length gate (sonnet)

**Files:**
- Add (commit): `TranslateCallTests/Integration/QwenCloneProbeTests.swift` (rewritten)
- Create: `tools/scripts/qwen-probe.sh`; Modify: `justfile` (recipe `qwen-probe`)

**Behaviour:**
- Suite enabled only with `TC_QWEN_PROBE == "1"` (as today).
- Reads every `<n>s.wav` + `<n>s.txt` in `build/qwen-probe/refs/` (absolute path from env `TC_QWEN_PROBE_REFS`, set by the script). WAV through `AVAudioFile`, converted to 24 kHz mono Float. Adds the active profile (the 31 s voice) as reference `31s`.
- Sentences: es "Creo que deberíamos revisar el presupuesto antes de la reunión del jueves.", es "¿Te viene bien que hablemos mañana por la tarde?", en "I think we should review the budget before Thursday's meeting.", en "Could we talk tomorrow afternoon instead?".
- For each reference: load the model once, then for each sentence one **cold** run (the first after load, only for the first sentence) and **warm** runs. Use `model.generateStream(..., streamingInterval: 0.32)` and record first chunk, total, audio seconds and tokens/s.
- Writes `build/qwen-probe/<timestamp>/<n>s/<lang>-<k>.wav` and `summary.md` (one row per reference × sentence; cold row marked). Prints the summary path.
- `tools/scripts/qwen-probe.sh`: the bench's Release `build-for-testing` (`tools/scripts/bench.sh:95`, same `xcb` and Release settings as `db6c038`), then `test-without-building -only-testing:TranslateCallTests/QwenCloneProbeTests` with `TEST_RUNNER_TC_QWEN_PROBE=1 TEST_RUNNER_TC_QWEN_PROBE_REFS=$PWD/build/qwen-probe/refs`.

- [x] **Step 1:** Write the probe and the recipe.
- [x] **Step 2:** `just test` → the probe suite is skipped (no env). `just qwen-probe` with an empty refs folder → runs the `31s` reference only and writes a summary.
- [x] **Step 3:** Commit `test(tts): Qwen reference-length probe in Release (REQ-QS-30)`.

### P-1 — STOP: the user records and picks the reference length (user)

Ask the user to record three clips, in the same room and with the same microphone as their 31 s voice:
1. QuickTime Player › File › New Audio Recording; read the text calmly; stop; File › Export As › Audio Only (`.m4a`).
2. Convert each: `afconvert -f WAVE -d LEI16@24000 -c 1 <in>.m4a build/qwen-probe/refs/<n>s.wav`.
3. Save the exact text read as `build/qwen-probe/refs/<n>s.txt` (UTF-8, one line). If a word was misread, write what was said.

Draft texts (Spanish, no numbers or names):
- **5 s** (`5s`): "Hola, soy yo. Esta es mi voz de siempre, hablando con calma."
- **8 s** (`8s`): "Buenos días. Estoy grabando mi voz para que la aplicación pueda hablar como yo cuando converso con otras personas."
- **10 s** (`10s`): "Me gusta hablar despacio y con claridad. Cada mañana preparo un café, reviso los mensajes pendientes y organizo el trabajo del día con mis compañeros."

Then run `just qwen-probe` and give the user the summary path and the WAV folders. They listen to each reference's sentences and pick the **shortest length that still sounds like them**.
- Record the pick, the probe numbers and the cold/warm ratio in this file (a "P-1 result" line here) and in memory.
- The pick sets `guidedTargetSeconds` and the guided texts' length in Task 7.
- If cold first chunk > 1.5× warm → Task 10 runs; else Task 10 is skipped (write why).
- If none under 31 s sounds right: **stop** and present options (keep long voices + streaming only; or another approach). Do not continue phase 2.

### Task 7: Guided texts and reference constants (sonnet)

**Files:** Create `TranslateCall/Core/VoiceCloning/GuidedReadingTexts.swift`; Modify `QwenCloneConfiguration.swift`; Test `TranslateCallTests/GuidedReadingTextsTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated enum GuidedReadingTexts { static func text(for language: String) -> String }`, keyed like `QwenCloneConfiguration.supportedLanguageList`, with English as the fallback;
  - in `QwenCloneConfiguration`: `static let guidedTargetSeconds: Double = <P-1 pick>`, `static let guidedMaxSeconds: Double = 15`, `static let freeMaxSeconds: Double = 30`, `static let longReferenceSeconds: Double = 12`.
- Texts (design §7.1): natural, neutral, phonetically varied, no numbers, abbreviations or names. Length for the P-1 pick at a calm pace: ~2.5 words/s for es/en/fr/de/it/pt/ru; for zh/ja/ko ~5 characters/s. Spanish = the P-1 text of the picked length. Check zh/ja/ko/ru by back-translating with Apple Translation or a model, and fix anything that reads oddly.

- [x] **Step 1: Failing tests:** `everyLanguageHasText` (each `supportedLanguageList.key` has a non-empty text, distinct from English except `"english"`); `lengthMatchesTarget` (word count for space-separated languages within `targetSeconds × 2.5 ± 30 %`; character count for zh/ja/ko within `targetSeconds × 5 ± 30 %`); `noDigits` (no `0-9` in any text); `unknownLanguageFallsBackToEnglish`.
- [x] **Step 2:** `just test-only GuidedReadingTextsTests` → FAIL. **Step 3:** implement. **Step 4:** → PASS.
- [x] **Step 5:** Commit `feat(voice): guided reading texts for a short reference (REQ-QS-12/13)`.

### Task 8: Recording modes — auto-stop, grade, save block, active voice (sonnet)

**Files:** Create `Core/VoiceCloning/VoiceRecordingMode.swift`; Modify `VoiceProfileRecorder.swift`, `VoiceProfileManager.swift`, `Features/VoiceCloning/VoiceTranscriptView.swift:18-20`; Test `TranslateCallTests/VoiceRecordingModeTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated enum RecordingMode: Sendable, Equatable { case free; case guided(language: String) }` with `var maxSeconds: Double` (30 / 15) and `var guidedText: String?`.
  - `nonisolated enum VoiceQualityRules { static func grade(peakRmsDbfs: Float, hasClipping: Bool, voicedSeconds: Float, mode: RecordingMode) -> VoiceQualityGrade; static func isSaveBlocked(_ quality: VoiceQualityMetrics, mode: RecordingMode) -> Bool }`:
    - free: today's rule (poor if peak < −30, voiced < 8 or clipping; fair if peak < −20 or voiced < 20; else good). Blocked if poor and voiced < 8.
    - guided: poor if peak < −30, clipping, or voiced < `0.6 × guidedTargetSeconds`; fair if peak < −20; else good. Blocked if poor and voiced < `0.6 × guidedTargetSeconds`.
  - `VoiceProfileRecorder.stopRecording(mode: RecordingMode = .free) throws -> RecordingResult` grades through `VoiceQualityRules`. Leading and trailing silence above 0.3 s is trimmed before grading (−40 dBFS threshold, the one `computeQualityStatic` uses); the recorder has none today.
  - `VoiceProfileManager`: `@Published private(set) var recordingMode: RecordingMode = .free`; `func startRecording(mode: RecordingMode = .free) async`; auto-stop at `mode.maxSeconds` (P5); `stopRecording()` passes the mode; `saveProfile(name:transcript:result:makeActive: Bool = false)` sets the active profile when true (P12).
  - `VoiceTranscriptView` pre-fills `transcript` with `profileManager.recordingMode.guidedText` when empty, and blocks saving with `VoiceQualityRules.isSaveBlocked(result.quality, mode: profileManager.recordingMode)`.

- [x] **Step 1: Failing tests:** `freeRuleUnchanged` (table from today's thresholds); `guidedShortIsGood` (voiced 7 s, peak −18, no clip, target 8 → `.good`; voiced 4 s → `.poor` and blocked); `guidedMaxSeconds` (`RecordingMode.guided(language: "spanish").maxSeconds == 15`); `trimSilence` (0.5 s silence + 1 s tone + 0.5 s silence at 24 kHz → ~1 s ± 0.05 s after trim); `saveMakesActive` (manager with a mock store and a suite `UserDefaults`; `makeActive: true` → `activeProfileId` = the new id).
- [x] **Step 2–4:** `just test-only VoiceRecordingModeTests VoiceProfileManagerTests` FAIL → implement → PASS (`saveMakesActive` goes in the existing `VoiceProfileManagerTests`).
- [x] **Step 5:** Commit `feat(voice): guided recording mode — limits, grade and save rules (REQ-QS-11/12/16)`.

### Task 9: Guided recording UI and the long-voice hint (sonnet)

**Files:** Create `Features/VoiceCloning/GuidedRecordingChoiceView.swift`; Modify `VoiceRecordingView.swift`, `VoiceProfileListView.swift` (entry point), `Features/Settings/VoiceProfileRow.swift`, `VoicesSettingsView.swift`

Behaviour (design §7.2, §7.4):
- "New voice" opens the choice: **"Read a short text (recommended)"** / **"Use my own text"**.
- Guided: a language picker over `QwenCloneConfiguration.supportedLanguageList`, defaulting to `QwenCloneConfiguration.language(for: Locale(identifier: languagePairManager.sourceLanguage.minimalIdentifier)) ?? "english"`; the text shown large (`.title3`, wraps); progress and labels from `mode.maxSeconds` (no hard-coded 30); then `startRecording(mode: .guided(language:))`.
- `VoiceProfileRow`: when `profile.durationSeconds > QwenCloneConfiguration.longReferenceSeconds`, a secondary line "Long sample: a short recording answers faster" and a "Record short sample" button that opens the guided flow with `makeActive: true` at save.
- Strings through the String Catalog; system font, SF Symbols, `Theme` colours; `#Preview`s for the choice view, the guided recording view and a long-voice row, in light and dark.

- [x] **Step 1:** Implement; previews compile (`just build`).
- [x] **Step 2:** Render the three views light and dark through an offscreen `NSHostingView` (temporary, uncommitted test) and check text fit and the hint.
- [x] **Step 3:** `just test` → green; `just lint`.
- [x] **Step 4:** Commit `feat(voice): guided short recording and the long-voice hint (REQ-QS-10/14/15)`.

### Task 10: Warm-up (sonnet) — only if P-1 says so

**Files:** `QwenCloneModelManager.swift` (`func warmUp(profileStore: any VoiceProfileStoring, activeProfileId: UUID) async`); the call goes next to `warmUpTranslation()` at session start (`AudioCoordinator.swift:216`), only when the outgoing TTS is the clone.
- `warmUp` runs `synthesizeStream` with the active profile and the text "Hola." / "Hello." (language from the target locale), drains it and ignores errors. It goes through the gate like any inference.
- Test `warmUpDrainsThroughGate` (mock stream, the gate is idle after it) in `QwenCloneModelManagerTests`.
- Commit `feat(tts): warm the voice clone at session start (REQ-QS-31)`.
- Skipped → write "Task 10 skipped: cold/warm = x.x (≤ 1.5)" in P-1's result line.

### Gate G2 (phase 2)

- [x] `just build && just check && just test` → green.
- [x] The user makes a short voice in the app with the guided flow (Spanish) and leaves it active. Run `just bench pr best`: `voiceProfileSeconds` is the short one. Record totals and `clone.firstChunkMs`; expected ~1.8–1.9 s total.
- [x] Whole-phase review (opus) of T6–T10.

---

## Phase 3 — Early processing at the end of a turn

### Task 11: Translation handlers out of the pipeline file, in two halves (sonnet)

**Files:** Create `Core/Audio/AudioCoordinator+Translation.swift`; Modify `AudioCoordinator+Pipeline.swift` (remove `handleOutgoingTranslation`, `handleIncomingTranslation`, `warmUpTranslation`, `handleTranslationFailure`, `makeAlertItem`, lines ~272–398)

**Interfaces:**
- Produces, in the new extension (internal, MainActor):
  - `func translateOutgoing(_ text: String) async throws -> String`, `func translateIncoming(_ text: String) async throws -> String`: the `translate(text:from:to:)` calls only;
  - `func deliverOutgoing(_ text: String, translation: Task<String, Error>) async`, `func deliverIncoming(_ text: String, translation: Task<String, Error>) async`: today's bodies from the mute-turn / `isPaused` / empty guards through `appendTranscript` → `isOutgoingTranslating` → `await translation.value` → `completeTranscript` → `speak`, and errors → `skipTranscript` + `handleTranslationFailure`;
  - `handleOutgoingTranslation(of:)` / `handleIncomingTranslation(of:)` stay as one-liners: `await deliverOutgoing(text, translation: Task { try await translateOutgoing(text) })`. Behaviour is identical.
- [x] **Step 1:** Move and split. **Step 2:** `just test-only AudioCoordinatorTranslationTests AudioCoordinatorTTSTests AudioCoordinatorSessionTests AudioCoordinatorTests` → PASS unchanged. `wc -l AudioCoordinator+Pipeline.swift` ≤ ~280.
- [x] **Step 3:** Commit `refactor(audio): translation handlers in their own file, translate and deliver apart`.

### Task 12: Segment protocol and tentative VAD segments (opus)

**Files:**
- Modify: `Core/VAD/VADService.swift`, `SileroVADService.swift`, `EnergyVADService.swift`, `Core/Trace/TracingDecorators.swift` (`TracingVADService`)
- Create: `Core/VAD/TentativeTracker.swift`
- Modify mocks: `TranslateCallTests/Mocks/MockVADService.swift`, the private `MockVADService` in `TranslateCallTests/VADServiceTests.swift:40`
- Test: `TranslateCallTests/TentativeTrackerTests.swift`, `TranslateCallTests/EnergyVADTentativeTests.swift`

**Interfaces:**
- Produces:
  - `SpeechSegment` gains `var id: UInt64 = 0`, `var kind: SegmentKind = .final` (defaults keep every existing `SpeechSegment(audio:capturedAt:)` call compiling);
  - `nonisolated enum SegmentKind: Sendable, Equatable { case tentative, final }`; `nonisolated enum SegmentBoundary: Sendable, Equatable { case commit(UInt64), retract(UInt64) }`;
  - `VADService.boundaryEvents: AsyncStream<SegmentBoundary>` (`nonisolated var`, protocol requirement), implemented by both VADs, `TracingVADService` (passthrough of `inner.boundaryEvents`) and both mocks (`MockVADService.injectBoundary(_:)`);
  - `nonisolated struct TentativeTracker: Sendable`: `mutating func silenceStarted() -> UInt64?` (opens a tentative id if none is open, else nil), `mutating func speechResumed() -> SegmentBoundary?` (`.retract` for the open id), `mutating func ended() -> SegmentBoundary?` (`.commit` for the open id), `mutating func forced() -> SegmentBoundary?` (`.retract` for the open id; used before a force-emit or a flush), `mutating func nextFinalID() -> UInt64`. Ids increase across tentatives and finals.
- Silero (P6): after each `processStreamingChunk`, compare old and new `tempEndSample` while `triggered`:
  - nil → non-nil: `silenceStarted()` → yield `.tentative` with `utteranceBuffer` so far (min-speech check as `yieldUtterance`);
  - non-nil → nil while still triggered: `speechResumed()` → yield the boundary;
  - `.speechEnd`: `ended()` → yield `.commit` and **no** new segment when a tentative is open; else `.final` as today;
  - force-emit and flush: `forced()` then `.final`, as today.
- Energy: tentative when `silenceSamples` first reaches `0.2 × sampleRate` inside `.speaking`; retract on speech before `minSilenceSamples`; commit at `minSilenceSamples`; force-emit/flush as Silero.
- `vadStateEvents` unchanged.

- [x] **Step 1: Failing tests:**
  - `TentativeTrackerTests.commitPath` (silenceStarted → 1; ended → `.commit(1)`; nextFinalID → 2);
  - `retractThenCommit` (silenceStarted → 1; speechResumed → `.retract(1)`; silenceStarted → 2; ended → `.commit(2)`);
  - `noOpenTentative` (ended → nil; speechResumed → nil);
  - `forcedRetracts` (silenceStarted → 1; forced → `.retract(1)`; nextFinalID → 2).
  - `EnergyVADTentativeTests`: synthetic 16 kHz buffers (tone −20 dBFS / silence), default config (pause 0.6):
    - `tentativeThenCommit`: 1 s tone + 0.7 s silence → segments `[.tentative id 1]`, boundaries `[.commit(1)]`;
    - `hesitation`: 1 s tone + 0.3 s silence + 1 s tone + 0.7 s silence → segments `[tentative 1, tentative 2]`, boundaries `[.retract(1), .commit(2)]`; segment 2's audio ≥ 2.2 s (whole utterance);
    - `maxDurationForces`: `maxSpeechDuration = 1`, 1.5 s tone → one `.final`, no boundary.
- [x] **Step 2:** `just test-only TentativeTrackerTests EnergyVADTentativeTests` → FAIL.
- [x] **Step 3:** Implement. Silero's path is covered by the tracker tests plus the existing `SileroVADIntegrationTests` (integration tier).
- [x] **Step 4:** `just test-only TentativeTrackerTests EnergyVADTentativeTests VADServiceTests TracingDecoratorTests VADProviderTests` → PASS; `just test-integration` VAD suites → PASS.
- [x] **Step 5:** Commit `feat(vad): tentative segments with commit and retract (REQ-QS-40/43/44)`.

### Task 13: STT passes the segment through, always (sonnet)

**Files:** Modify `Core/STT/SpeechRecognizerService.swift` (`TranscriptionResult`), `AppleSpeechService.swift`, `ParakeetSpeechService.swift`, `WhisperSpeechService.swift`, `Core/Trace/TracingDecorators.swift` (`TracingSTTService` keeps the fields); Test `TranslateCallTests/STTSegmentTaggingTests.swift`

**Interfaces:**
- Produces: `TranscriptionResult` gains `var segmentID: UInt64 = 0`, `var kind: SegmentKind = .final`, and `static func empty(for segment: SpeechSegment, locale: Locale) -> TranscriptionResult` (text "", confidence 0). Each engine sets `segmentID`/`kind` from the segment, and yields `.empty(for:locale:)` wherever it yields nothing today (P4).
- [x] **Step 1: Failing tests:** `STTSegmentTaggingTests.emptyResultCarriesSegment` (`.empty(for: SpeechSegment(..., id: 7, kind: .tentative), locale:)` → `segmentID == 7`, `kind == .tentative`, text ""); `ParakeetSpeechServiceTests.noResultStillYieldsEmpty` (the existing Parakeet test harness with a silent segment `id: 3` → one result, empty text, `segmentID == 3`); `tagsPassThrough` (Parakeet mock result → `segmentID`/`kind` copied).
- [x] **Step 2–4:** `just test-only STTSegmentTaggingTests ParakeetSpeechServiceTests STTServiceTests TracingDecoratorTests` FAIL → implement → PASS. Apple and Whisper are covered by review and the integration tier (`just test-integration`).
- [x] **Step 5:** Commit `feat(stt): every segment yields a result tagged with its id (FR-QS.5, P4)`.

### Task 14: TurnCommitter and the coordinator wiring (opus)

**Files:** Create `Core/Audio/TurnCommitter.swift`; Modify `AudioCoordinator.swift` (properties), `AudioCoordinator+Pipeline.swift` (observe transcriptions and boundaries through the committer; teardown); Test `TranslateCallTests/TurnCommitterTests.swift`, `TranslateCallTests/AudioCoordinatorEarlyProcessingTests.swift`

**Interfaces:**
- Consumes: `deliverOutgoing/Incoming`, `translateOutgoing/Incoming` (Task 11); `SegmentBoundary`, `boundaryEvents` (Task 12); tagged `TranscriptionResult` (Task 13).
- Produces: `final class TurnCommitter` (MainActor):
  - `typealias Translate = @MainActor (String) async throws -> String`
  - `typealias Deliver = @MainActor (_ text: String, _ translation: Task<String, Error>) async -> Void`
  - `init(translate: @escaping Translate, deliver: @escaping Deliver)`
  - `func receive(_ result: TranscriptionResult)`, `func receive(_ boundary: SegmentBoundary)`, `func cancelAll()`
  - `var heldCount: Int` (tests)
- Rules (design §10.4, P7):
  - per id: text (from the result), a translation `Task` started on a non-empty result, `committed`;
  - `.final` result → committed at once;
  - `.commit(id)` before its result → committed, waits for the text;
  - `.retract(id)` → cancel the translation, forget the id;
  - delivery: one serial loop in id order. The head is delivered once committed and its text known; empty text is skipped without blocking;
  - `cancelAll()` cancels and forgets everything; nothing held is delivered afterwards.
- Coordinator: `outgoingCommitter` / `incomingCommitter` (`TurnCommitter?`), created in `startOutgoingPipeline` / `activateIncoming` with `translate: { try await self.translateOutgoing($0) }` and `deliver: { await self.deliverOutgoing($0, translation: $1) }`. `observeOutgoingTranscriptions` feeds results to the committer, sets `outgoingTranscription` only for non-empty text, and no longer calls `handleOutgoingTranslation`. A new task observes `vad.boundaryEvents` into the committer. Teardown calls `cancelAll()` and nils it. Mute turn and pause apply at delivery (they already sit in `deliverOutgoing`).
- [x] **Step 1: Failing tests** (`TurnCommitterTests`, closures recording calls, translation stubs gated by `AsyncGate`):
  - `commitAfterTranslation`: tentative "hola" (id 1) → translate called once; not delivered; `.commit(1)` → delivered `("hola", "hello")`;
  - `commitBeforeResult`: `.commit(1)` then the result → delivered once;
  - `retractCancels`: tentative 1, `.retract(1)` → its translation task is cancelled; nothing delivered; `heldCount == 0`;
  - `twoHesitationsOneSentence`: tentative 1 "creo que", retract 1, tentative 2 "creo que eh", retract 2, tentative 3 "creo que eh si revisamos", commit 3 → exactly one delivery, text "creo que eh si revisamos";
  - `inOrder`: tentatives 1 and 2; translation 2 finishes first; commits 2 then 1 → delivered 1 then 2;
  - `emptyCommitDoesNotBlock`: tentative 1 with "" + commit 1, then final 2 "vale" → only "vale" delivered;
  - `finalsUnchanged`: a `.final` result is delivered with no boundary;
  - `stopDropsHeld`: tentative 1, `cancelAll()`, `.commit(1)` → nothing delivered.
  - `AudioCoordinatorEarlyProcessingTests` (the existing coordinator harness with `MockVADService` / mock STT / fake TTS):
    - `tentativeSpokenAtCommit`: inject a tentative segment and its result → no transcript entry, `speak` not called; inject `.commit` → one entry and one `speak` with the translation;
    - `retractedNeverShown`: tentative + retract → no entry, no `speak`;
    - `pausedCommitShownNotSpoken`: pause, then commit → entry shown, `speak` not called.
- [x] **Step 2:** `just test-only TurnCommitterTests AudioCoordinatorEarlyProcessingTests` → FAIL.
- [x] **Step 3:** Implement.
- [x] **Step 4:** `just test-only TurnCommitterTests AudioCoordinatorEarlyProcessingTests AudioCoordinatorTranslationTests AudioCoordinatorTTSTests AudioCoordinatorSessionTests AudioCoordinatorEchoGateTests AudioCoordinatorTests` → PASS; repeat the two new suites 20 times → no flake.
- [x] **Step 5:** Commit `feat(audio): translate at the first silence, speak at the end of the turn (REQ-QS-41/42/44/45)`.

### Task 15: Tracer and bench for tentatives (sonnet)

**Files:** Modify `Core/Trace/TraceEvent.swift` (`TraceStage.committed`, `.retracted`), `Core/Trace/PipelineTracer.swift` (`segmentCommitted(capturedAt:)`, `segmentRetracted(capturedAt:)`), `TracingDecorators.swift` (`TracingVADService` calls them from the boundary stream; it already calls `segmentClosed` per segment); `tools/bench/tcbench/analyze.py`, `report.py` + tests; Test `TranslateCallTests/PipelineTracerTests.swift`

- Tracer (P10): `segmentRetracted` emits `.retracted` for the open utterance with that `capturedAt` (the latest tentative) and forgets it. `segmentCommitted` emits `.committed`. Matching of STT results by `capturedAt` keeps working: each tentative opens its own utterance, and a retracted one is gone before the next opens.
- `analyze.py`: seqs with `retracted` are excluded from clip matching, WER, cut rate and latency. New per profile/direction: `turn.retractPct` = retracted / (retracted + committed + finals), and `turn.commitMs` p50 = `committed − ground-truth speech end`. Informative.
- [x] **Step 1: Failing tests:** `PipelineTracerTests.retractedUtteranceForgotten` (segmentClosed A, segmentRetracted A, segmentClosed A′ with the same `capturedAt`, sttFinal → matched to A′; events contain `.retracted` for A's seq); `committedStamped`. Python: `test_analyze.py::test_retracted_excluded`, `test_turn_stats`.
- [x] **Step 2–4:** `just test-only PipelineTracerTests TracingDecoratorTests` and `just test-bench-tools` FAIL → implement → PASS.
- [x] **Step 5:** Commit `feat(bench): trace commit and retract; report the turn stats (REQ-QS-23)`.

### Gate G3 (phase 3)

- [x] `just build && just check && just test && just test-integration` → green.
- [x] `just bench pr basic` and `just bench pr best` (short voice). `just bench-compare` on Basic against the baseline: WER and cut-rate verdicts ✅ (NFR-QS-05). Record totals (Best expected ~1.45–1.6 s), `turn.retractPct`, `turn.commitMs`.
- [x] Whole-phase review (opus) of T11–T15.

---

## Phase 4 — Shorter pause (conditional) and acceptance

### Task 16: Default pause 0.4 s — only if G3's Best p50 ≥ 1.5 s in a gated direction (sonnet)

**Files:** `Core/Audio/ConversationSettings.swift` (`defaultPauseSeconds = 0.4`); tests in `ConversationSettingsTests`: `defaultIs04` and `savedValueKept` (a suite `UserDefaults` holding 0.6 → still 0.6).
- Re-run `just bench pr basic` and `best`; Basic cut-rate verdict must stay ✅. If it fails: **stop** and present options to the user (keep 0.6 with the current total; a value between; wait for the semantic turn detector).
- Commit `feat(audio): default pause to translate 0.4 s (REQ-QS-46)`.
- Task 16 skipped: G2 bench with the 7.61 s guided voice: Best p50 = 1.23–1.30 s in all gated directions, < 1.5 s.

### Gate G4 — acceptance run

- [ ] A **full** bench run, Best local, short voice, overnight with `caffeinate` (Basic's full run takes ~3 h 27 min; Best is similar or longer): `just bench full best`. NFR-QS-01 (p50 < 1.5 s, p90 < 2.0 s per gated clone direction), NFR-QS-02 (gaps ≤ 5 % of clone sentences), NFR-QS-05 (cut rate and WER within the thresholds).
- [ ] If NFR-QS-01 misses: **stop** and present the numbers and options to the user; do not ship as accepted.
- [ ] New baselines: `just bench-baseline <run> "qwen-streaming: clone streaming, short reference, early end-of-turn"` for Best (and Basic, from a full Basic run).

### Task 17: Docs, backlog and the gate (sonnet)

- [x] `specs/m9-product/backlog.md`:
  - close UI-S3;
  - add: cancellable mlx-audio generation (upstream), the semantic end-of-turn pilot (Namo, `research-end-of-turn.md`), streaming in the preview (Q-3, if ever wanted);
  - add the feature line `Voice-clone streaming | m9-product/qwen-streaming/ | …`.
- [x] `docs/ARCHITECTURE.md`: gate streaming, the clone stream, tentative/commit/retract and `TurnCommitter`.
- [x] Tick the steps in this file; commit `docs(m9): qwen-streaming architecture and backlog`.
- [ ] `just pr` → green (pushes, opens the PR with the template). A known flake (A28 integration host exit) → re-run once and report. Never mark tests as known issues without asking.

### Task 18: Manual checklist (user, before merge)

In a Release build (the bench's `build/DerivedData/Build/Products/Release/TranslateCall.app` or an archive):
- Q1: a real call, Spanish → English with the short voice. The other side hears the cloned voice promptly and fluently, without choppy audio.
- Q2: the same with the 31 s voice. Slower but fluent; the long-voice hint shows in Settings › Voices.
- Q3: "Record short sample" from the hint → the guided flow in Spanish and in English; the new voice becomes active.
- Q4: stop mid-sentence and talk again at once → the next sentence is in the standard voice, then the clone comes back.
- Q5: hesitations (read `bench/prompts/es-ES.md` rows 17–19 with the pauses) → not cut more than before; each sentence is spoken once, whole.
- Q6: incoming direction still works (the other side's speech is translated and spoken to the user).
- Q7: the voice preview in Settings › Voices still works (non-streaming).

---

## Replay notes

Replayed on 2026-10-31 in a throwaway clone of `spec/m9-qwen-streaming` at f069e24 with `db6c038` cherry-picked (clean), own DerivedData, shared SourcePackages. The clone was deleted afterwards.

**Replayed:**
- Task 1: the full gate stream (`GateStreamLink`, `StreamRelay`, `runStream`, `isHeldByAbandonedStream`, the `currentStream` hook in `release()`);
- Task 2: the client over `generateStream`, `QwenCloneModelManager.synthesizeStream` (not-ready, abandoned and gated paths), `GatedQwenInferrer` relay, mock default stream, config values, `gateBusyAbandoned`;
- Task 12/13: the protocol types (`SpeechSegment.id/kind` defaults, `SegmentKind`, `SegmentBoundary`, `boundaryEvents` on all five conformers, `TranscriptionResult.segmentID/kind` defaults);
- Task 14: a first `TurnCommitter` shape (MainActor, per-id entries, serial in-order drain).

**Checks run:**
- `build-for-testing` → TEST BUILD SUCCEEDED. No new warnings; the existing ones in `AudioManager`, `LanguageSection`, `StatusPanel` and `LanguagePairManagerTests` are unrelated.
- Two smoke tests (abandoned stream keeps the gate until the inner ends; the first-element timeout with the gate staying busy), plus `MLXInferenceGateTests` and `QwenUtteranceSynthesizerTests`: 13 tests, all passed.
- `swiftlint --strict` on the new and changed files: one violation, `multiple_closures_with_trailing_closure` at the `runStream` call. Fixed in the plan by labelling `work:` (P2).

**Fixed in the plan while replaying:**
- `runStream`'s `work:` label (lint);
- `isFirst`, so `.info` does not stop the first-chunk timer;
- dropping the iterator does not end an `AsyncThrowingStream` consumer: the tests cancel a consuming `Task`;
- the gate's `clock`, `acquire` and `release` must be internal for the extension in another file.

**Not replayed:** Tasks 3–11 and 15–18 (UI, bench Python, the engines' bodies, the coordinator wiring).
