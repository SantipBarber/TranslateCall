# M9 Benchmark & Eval Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible benchmark that feeds recorded speech in real time through the production pipeline, traces every utterance, and turns the traces into latency (p50/p90) and quality numbers (WER, cuts, chrF++, COMET). The results are compared with a committed baseline, shown as a ✅/❌ table and an HTML report, and the PR set gates `just pr`.

**Architecture:**
- Production gains one opt-in module, `TranslateCall/Core/Trace/`. It holds `PipelineTracer` and pass-through decorators for each stage. Whoever builds `AudioCoordinator` can wrap its factories; the app wraps none today.
- The Swift runner lives in the test target, in a new `bench` tier:
  - it builds the coordinator the way `AppContainer` does, swapping in file sources (`BenchClipPlayer`) and a fake output that plays at once;
  - it writes one `raw.json` per run line × profile.
- A Python package, `tools/bench` (`tcbench`, run with `uv`), handles the data and the numbers:
  - fetches datasets and builds the manifest;
  - computes every metric;
  - compares with the baseline;
  - renders the report.

  Two golden JSON samples pin the manifest and `raw.json` contracts on both sides.

**Tech Stack:**
- Swift side: Swift 6 (app target with default MainActor isolation), `OSSignposter`, `Synchronization.Mutex`, Swift Testing, `xcodebuild` test plans.
- Python side: Python 3.12 with `uv`, `huggingface_hub`, `soundfile`, `soxr`, `numpy`, `silero-vad`, `sacrebleu`, `jinja2`, optional `unbabel-comet`, `pytest`.
- Tooling: `just`, opengrep, SwiftLint.

**Spec:** `specs/m9-product/benchmark-harness/requirements.md`, `design.md`, `design-brief.md` (DRAFT 2026-10-17).

## Global Constraints

- **Branches.** Branch `feat/m9-benchmark-harness`, created from `spec/m9-benchmark` **after rebasing `spec/m9-benchmark` on `main`**. Rebase once the UI thread's PR `fix/a26-main-window-launch` has merged (see P6). Spec and code ship in one PR. Never commit to `main`.
- **Commits.** Conventional Commits, ending with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```
- **Toolchain.**
  - Xcode **27.1** on the Mac mini. `tools/versions.env` `XCODE_VERSION` becomes 27.1 through the UI thread's PR; if it hasn't merged yet, Task 7 makes the same bump.
  - `SWIFT_VERSION = 6.0`, `MACOSX_DEPLOYMENT_TARGET = 15.0`.
  - The app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so new production types in `Core/Trace` are declared `nonisolated` unless they must be MainActor.
  - New files are picked up automatically (`PBXFileSystemSynchronizedRootGroup`): never edit `project.pbxproj`. The shared scheme `TranslateCall.xcodeproj/xcshareddata/xcschemes/TranslateCall.xcscheme` *is* edited, to register the Bench test plan.
- **SwiftLint**, for the app target only (`TranslateCallTests` is excluded):
  - lines ≤ 120;
  - function bodies ≤ 50 lines, type bodies ≤ 250 lines, files ≤ 400 lines;
  - identifiers ≥ 3 characters (so no `at`; use `time`/`stamp`);
  - no force unwraps; sorted imports.
- **`AudioCoordinator.swift` is at 398/400 lines and is not modified** (P1).
- **Tests.**
  - Unit: `just test-only <SuiteTypeName> …`. They use no ML model, no network and no audio device, and no fixed sleeps: use `waitUntil` from `TranslateCallTests/Support/AsyncTestHelpers.swift`.
  - Integration tier: `just test-integration`.
  - Bench tier:
    ```bash
    xcodebuild -project TranslateCall.xcodeproj -scheme TranslateCall -destination platform=macOS \
      -derivedDataPath build/DerivedData test-without-building -testPlan Bench \
      -only-testing:TranslateCallTests/BenchTests[/<Suite>] 2>&1 | xcbeautify
    ```
    Run `build-for-testing` first. Bench parameters reach the test host as `TEST_RUNNER_TC_BENCH_*` environment variables, which `xcodebuild` strips to `TC_BENCH_*`.
  - Python: `uv run --project tools/bench pytest -q`.
- **Missing prerequisites fail, never skip.** Use `requirePrerequisite(_:_:)` from `TranslateCallTests/Integration/Prerequisites.swift`, which is visible from `Bench/` because it is in the same target.
- **`just pr` precondition (P7).** `EdgeTTSIntegrationTests` (backlog A11) fails on `main` today: Microsoft returns 403 on the WebSocket upgrade. The UI thread's PR is expected to wrap it in `withKnownIssue` (A27). No step below relies on `just pr` being green until that lands; Task 16 checks for it first.
- **Licences.** The allow-list is FLEURS CC BY 4.0, VoxPopuli CC0, Common Voice CC0 (gated, optional), Smart Turn v3 test CC BY 4.0, NTREX CC BY-SA 4.0 and `Unbabel/wmt22-comet-da` Apache-2.0.
  - Never commit audio or cache content.
  - Nothing non-commercial or no-derivatives: no CoVoST 2, MuST-C, mTEDx, CometKiwi or XCOMET.
- **Spanish variants.** `es-ES` and `es-419` are separate variants everywhere, and Smart Turn Spanish is `es-xx`. Never aggregate them together.
- **Strings.** UI strings stay English, specs are English, and the user is addressed in Spanish.

## Review Focus

- **A clip produces two STT utterances** (a premature cut). Latency must count only on the last one, the earlier one counts as a cut, and no utterance may be lost. Pinned in Task 9 `test_cut_clip_latency_on_last_seq` and Task 2 `segmentWithoutTranscriptIsDroppedWhenALaterOneIsTranscribed`.
- **The synthesizer's stream ends before the playback service schedules its buffers** (an actor hop). The first buffer must still count, and the utterance must not be reported "no audio". Pinned in Task 2 `bufferScheduledAfterTheSynthesizerFinishedStillCounts`.
- **The profile cannot run as asked**: Parakeet or the voice clone is missing, the VAD falls back to Energy, or STT falls back to Apple Speech. The run must fail naming the missing piece, never silently measure the wrong engines. Pinned in Task 5 `BenchSmokeTests.startRefusesEnergyVAD` and the `start(_:options:)` checks.
- **A run changes the user's settings.** The real defaults keys `tlk.*` and `conversation.*` must be identical before and after a run (NFR-BH-03). Pinned in Task 5 `BenchSmokeTests.userDefaultsUntouched`.
- **The baseline was made with another manifest or macOS build.** `compare` must refuse a manifest mismatch and warn on a macOS mismatch, never compare silently. Pinned in Task 10 `test_compare_refuses_manifest_mismatch` and `test_compare_warns_macos_change`.

## Decisions made while planning (P1 and P5 approved by the user 2026-10-17; P6 and P7 are met: PR #8 on main)

| # | Point | Choice |
|---|-------|--------|
| P1 ✅ (user OK 2026-10-17) | Wiring the trace (design §2.3 said `AudioCoordinator` gains `traceSink:`) | **`AudioCoordinator` is not touched.** `PipelineTracer` offers wrappers for every factory the coordinator already takes: `tracingVAD`, `tracingSTT`, `tracing(_ TranslationService)`, `tracingTTS`, `tracing(_ UtteranceSynthesizer)` and `tracing(_ AudioOutputting)`. The builder (the bench today, `AppContainer` later for the UI latency indicator) wraps them. Reasons: `AudioCoordinator.swift` is at 398 of SwiftLint's 400-line limit, and this leaves zero change on the audio path. design.md §2.3 gets a one-line update in Task 15. |
| P2 | Seq → clip assignment (design §3.4 placed it in Swift) | **Python does it** (`tcbench analyze`), from the clip feed windows and the utterance stamps in `raw.json`. Swift's idle wait only needs `PipelineTracer.openSeqs`. This keeps every metric in Python (D-11) and makes it unit-testable without audio. |
| P3 | Trace clock | `ContinuousClock.Instant` (mach continuous time) instead of a raw `UInt64`. `raw.json` stores Int64 ns offsets from the session's origin instant. Segment `capturedAt` (a `Date`) is mapped once per tracer (`originDate` ↔ `originInstant`). |
| P4 | TTS correlation | `TracingUtteranceSynthesizer` reports where each attempt starts, together with its (possibly merged) text. `TracingAudioOutput` reports each scheduled buffer. An attempt's first buffer is `ttsFirstBuffer` for every seq it carries (`mergedSeqs`). Retrying the same text before any audio counts as the fallback. `ttsEnd` means "synthesis delivered" because the bench output plays at once. The selector's synthesizer and output factories are shared by both directions, so the bench swaps them only for the duration of one direction's `make*Service` call (`BenchPipelineFactory.traced`). `TTSEngineSelector` is unchanged. |
| P5 ✅ (user OK 2026-10-17: PR MT-only = 100) | **Measure-first gate, run while planning** (Mac mini M4, macOS 26.6.2, Xcode 27.1, Basic profile, outgoing es→en, the `say` fixtures es-greeting and es-meeting, 2 sessions × 4 clips) | Two identical runs gave a median total latency of **1 523 ms and 1 521 ms** (run-to-run variance **0.13 %**). Per-clip overhead beyond the audio: **3.0 s** (idle wait plus gaps). Session start with warm-up: **2.2 s**. Direct Apple translation: **282 ms per sentence**. **Projected PR bench: 576 s (9.6 min) ≤ 600 s, so the gate passes, but tightly.** Of that, about 113 s is the MT-only set (2 × 200 × 282 ms). ⚑ **Proposal:** the PR tier uses **100 MT-only sentences per direction**, giving about 8.7 min; the full tier keeps 200. The first launch of the bench runner in the replay clone exited with code 0 mid-run (no crash report). It did not happen again on the next run, but Task 1 runs the gate twice and Task 6 records any repeat. |
| P6 | UI thread PR `fix/a26-main-window-launch` | That PR creates `TranslationHostWindow` hidden, adds `show()`, and makes `hostTranslationBridge()` call it. **After the rebase**, `BenchPipelineFactory.make` must call `host.show()` right after creating its `TranslationHostWindow` (Task 5, step marked P6). Before the rebase, `show()` does not exist: skip that line. |
| P7 | `just pr` red on `main` (A11 Edge 403) | This is a precondition, not a task. Tasks 1–15 verify with suite-level commands. Task 16 runs `just pr` only once `main` has the A27 known-issue wrap. |
| P8 | Spanish locale reaching STT | The bench sets the pair as the app stores it: `es-ES` / `es-419` / `en` / `es` in `tlk.source.language` / `tlk.target.language`. The coordinator passes `Locale(identifier: language.minimalIdentifier)` to STT. `es-ES` → `"es"` (the region is dropped as the likely one); `es-419` keeps `"es-419"`. The bench measures what the app does. Task 6 records the resolved STT locale per run line in `meta.engines["sttLocale"]`, so a surprise shows in the report. |
| P9 | Spanish STT in Best local | Apple Speech, as decided in requirements REQ-BH-31. Parakeet is gated to English in the app. |
| P10 | Bench audio of TTS output | `BenchOutput` keeps `(instant, buffer)` pairs, and the runner drains them after each clip into `audio/<seq>.wav`, so memory stays bounded on full runs. |

## File Structure

```
TranslateCall/Core/Trace/
  TraceEvent.swift                 NEW T2  TraceDirection, TraceStage, TraceEvent, TraceSink, NoopTraceSink
  PipelineTracer.swift             NEW T2  correlation + signposts
  TracingDecorators.swift          NEW T3  TracingVAD/STT/Translation/SynthesisService, TracingUtteranceSynthesizer, TracingAudioOutput
  PipelineTracer+Wiring.swift      NEW T3  factory wrappers (P1)
TranslateCallTests/
  Support/TestTier.swift           MOD T1  + .bench
  Support/Tags.swift               MOD T1  + .bench
  Support/CollectingTraceSink.swift NEW T2
  TestPlans/Bench.xctestplan       NEW T1
  PipelineTracerTests.swift        NEW T2
  TracingDecoratorTests.swift      NEW T3
  Bench/BenchTests.swift           NEW T1  root suite
  Bench/BenchClipPlayer.swift      NEW T1  ClipFeed, BenchClipPlayer, BenchAudioSource
  Bench/BenchPipelineFactory.swift NEW T1 (Basic) → T5 (profiles, tracing, BenchOutput, BenchSession)
  Bench/MeasureFirstTests.swift    NEW T1 → DEL T6
  Bench/BenchModels.swift          NEW T4  BenchManifest, RawRun, BenchJSON
  Bench/BenchModelsTests.swift     NEW T4  (runs in the unit tier: pure Codable)
  Bench/BenchSystemAudioCapture.swift NEW T5
  Bench/BenchRunner.swift          NEW T6  clip loop, idle wait, MT-only, writer, env parameters
  Bench/BenchRunLineTests.swift    NEW T6  one test per run line × profile
  Integration/BenchSmokeTests.swift NEW T5
  Integration/*.swift, Support/LatencyReport*.swift   MOD/DEL T15
TranslateCall.xcodeproj/xcshareddata/xcschemes/TranslateCall.xcscheme  MOD T1
tools/bench/                       NEW T7–T12  pyproject.toml, uv.lock, tcbench/, tests/ (+ fixtures/ golden samples from T4)
bench/                             NEW T8–T13 manifests/, prompts/, licences.json, thresholds.json, baseline.json (T16)
tools/scripts/{bench.sh,pr.sh,setup.sh}, tools/versions.env, justfile, .gitignore, .github/workflows/check.yml  T7, T14
specs/…/design.md, specs/m8.5-stabilization/{backlog.md,f8.5.0-dev-workflow/*}                         T15
```

Dependency order:
- Swift track: T1 (gate) → T2 → T3 → T4 → T5 → T6.
- Python track: T7 → T8 → T9 → T10 → T11 → T12. It can start after T4, which creates the golden samples.
- T13 (prompt sheets) needs nothing.
- T14 needs T6 and T10. T15 needs T6. T16 needs everything.

Replayed while planning on a throwaway clone (Xcode 27.1):
- Tasks 1–5's Swift code built (`build-for-testing`).
- `swiftlint --strict` was clean on `Core/Trace`.
- `PipelineTracerTests` and `TracingDecoratorTests` passed.
- The Task 1 gate ran end to end (P5).

---

### Task 1: Measure first — bench tier, real-time clip player, PR duration and variance — STOP GATE

**Files:**
- Modify: `TranslateCallTests/Support/TestTier.swift`: `case unit, integration, bench`
- Modify: `TranslateCallTests/Support/Tags.swift`: `@Tag static var bench: Self`
- Create: `TranslateCallTests/TestPlans/Bench.xctestplan`. Copy `Integration.xctestplan` and change: configuration id `8F5A0C1E-0000-4000-8000-000000000003`, `TC_TEST_TIER` = `bench`, `executionTimeAllowance` 7200.
- Modify: `TranslateCall.xcodeproj/xcshareddata/xcschemes/TranslateCall.xcscheme`: add a third `<TestPlanReference reference = "container:TranslateCallTests/TestPlans/Bench.xctestplan">` after the Integration one.
- Create: `TranslateCallTests/Bench/BenchTests.swift`, `Bench/BenchClipPlayer.swift`, `Bench/BenchPipelineFactory.swift`, `Bench/MeasureFirstTests.swift`

**Interfaces:**
- Consumes:
  - `AudioCapture` (`@MainActor`; `startCapture() async throws -> AsyncStream<AVAudioPCMBuffer>`, `stopCapture()`, `isCapturing`);
  - `SessionAudioStream.capacity` (64);
  - `FileAudioSource.decode16kMono(_:)`, `Fixtures.lang(_:)`, `Fixtures.url(for:)`;
  - `FakeOutput(autoComplete:)`, `MockSystemAudioCapture()`;
  - `requireSpeechAuthorization()`, `requireTranslationPack(from:to:)`, `hostTranslationBridge()`, `requirePrerequisite(_:_:)`, `waitUntil(timeout:_:)`, `Duration.milliseconds`;
  - `AudioCoordinator.init(…isTranslationPairInstalled:)`, `AppleTranslationService.isInstalled`, `LanguagePairManager(defaults:languageLoader:)`, `TranslationEngineSelector(outgoingBridge:incomingBridge:defaults:)`, `STTEngineSelector(defaults:)`, `TTSEngineSelector(defaults:)` with its `var outputFactory`, `ConversationSettings(defaults:).vadConfiguration`, `VADProvider().makeVAD(config:)` and `.activeEngine`.
- Produces (used by T5, T6):
  - `struct ClipFeed: Sendable { chunkTimes: [ContinuousClock.Instant]; chunk: Int; sampleRate: Double; var start; var end; func instant(ofSample:) -> ContinuousClock.Instant }`
  - `final class BenchClipPlayer: Sendable { static let sampleRate = 16_000.0; static let chunk = 1024; var isRunning: Bool; func start() -> AsyncStream<AVAudioPCMBuffer>; func stop(); func play(_ samples: [Float]) async -> ClipFeed; func playSilence(seconds: Double) async }`
  - `@MainActor final class BenchAudioSource: AudioCapture { let player: BenchClipPlayer }`
  - `struct BenchRunLine { userLanguage, otherLanguage, incoming, variant; static outgoingEsESToEn, outgoingEs419ToEn, outgoingEnToEs, incomingEnToEs }`
  - `struct BenchSetupError: Error, CustomStringConvertible`

The gate touches no production code.

- [ ] **Step 1: Bench tier.** Make the tier, tag, test plan and scheme edits listed under Files. Then add the root suite in `Bench/BenchTests.swift`:

```swift
@Suite("Bench", .tags(.bench), .serialized,
       .enabled(if: TestTier.current == .bench, "Bench tier only — run `just bench`"))
struct BenchTests {}
```

- [ ] **Step 2: `BenchClipPlayer`.**
  - It is a `Mutex`-guarded state holding:
    - `pending: (samples, offset, times, done: CheckedContinuation<ClipFeed, Never>)?`;
    - the stream continuation;
    - the feeding `Task`.
  - The stream has `bufferingPolicy: .bufferingNewest(SessionAudioStream.capacity)`.
  - Each period it pulls a 1024-sample chunk from `pending`, or silence.
  - **Timing rule (decides the ground truth):** the loop sleeps until an absolute deadline (`deadline += 1024/16 000 s`, `Task.sleep(until:clock: .continuous)`) and only **then** yields the chunk. A chunk is therefore delivered when its last sample would have been captured, as a mic tap delivers.
    ```swift
    func instant(ofSample index: Int) -> ContinuousClock.Instant {
        let chunkIndex = min(max(index, 0) / chunk, chunkTimes.count - 1)
        let samplesAfter = (chunkIndex + 1) * chunk - index
        return chunkTimes[chunkIndex] - .seconds(Double(samplesAfter) / sampleRate)
    }
    ```
  - `play` resumes once the clip's last chunk was yielded.
  - `stop()` finishes the stream and resumes any pending `play` with what was delivered.
  - The `Task.detached` closure must end in `return`, so it is `Task<Void, Never>` and not `Task<()?, Never>`.
  - `BenchAudioSource` forwards `startCapture`/`stopCapture`/`isCapturing` to its `player`.

- [ ] **Step 3: `BenchPipelineFactory.makeBasic(_ line: BenchRunLine, output: any AudioOutputting) throws -> BenchSession` (gate version).**
  - Build it like `AppContainer.init` (`TranslateCall/App/AppContainer.swift:34-60`), on `UserDefaults(suiteName: "bench-<uuid>")`.
  - Set `"tlk.source.language"` = `line.userLanguage` and `"tlk.target.language"` = `line.otherLanguage`.
  - `LanguagePairManager(defaults:languageLoader: { [] })`.
  - Its own `TranslationHostWindow` (P6: `host.show()` after the rebase).
  - `tts.outputFactory = { _ in output }`; `systemCapture: MockSystemAudioCapture()`; `isTranslationPairInstalled: AppleTranslationService.isInstalled`.
  - Do **not** call `vads.preload()`: in `.idle`, `makeVAD` loads Silero synchronously.
  - `BenchSession.tearDown()` stops the coordinator, closes the host and calls `UserDefaults.standard.removePersistentDomain(forName:)`.
  - In the same file, add `ScheduleLog: AudioOutputting`. It wraps `FakeOutput(autoComplete: true)` and records `ContinuousClock.now` at each `schedule`.

- [ ] **Step 4: Gate test `MeasureFirstTests.prDurationAndVariance()`** (an `extension BenchTests { @Suite("Measure first") @MainActor struct … }`).
  - **Prerequisites:** speech authorization, and the es→en and en→es packs.
  - **Runs.** Run two separate sessions of `.outgoingEsESToEn`. Each plays `Fixtures.lang("es")` twice (4 clips). Per session:
    - `start()`, then require `isOutgoingActive` and `vads.activeEngine == .silero`.
    - `playSilence(seconds: 2)`, the translation warm-up.
    - Per clip:
      - `play`;
      - `speechEnd = feed.instant(ofSample: lastLoudSample)`, where `lastLoudSample` is the last index with `|x| > 0.01`;
      - wait up to 15 s for a schedule time after `speechEnd`;
      - `playSilence(1.0)` and then `playSilence(0.5)`;
      - total = first schedule after `speechEnd` − `speechEnd`;
      - overhead = (`feed.start` → now) − the clip's audio seconds.
  - **MT-only cost:** `hostTranslationBridge()`, one warm `translate`, then the median of 4 Spanish sentences.
  - **Output:**
    - `projected = 56 × (5.0 + medianOverhead) + 7 × sessionStart + 400 × mtMs/1000`;
    - `variance = |medianA − medianB| / mean`;
    - write `build/bench/measure-first.json` (the repo root comes from `#filePath`, three levels up), print `BENCH-GATE …`;
    - `#expect(projected <= 600)` and `#expect(variance <= 0.05)`, each with a message ending "— STOP, see tasks.md Task 1".

- [ ] **Step 5: Build and run the gate twice.**

Run: `just build` is not enough; use `build-for-testing`, then the bench command from Global Constraints with `-only-testing:TranslateCallTests/BenchTests/MeasureFirstTests`, twice.
Expected: PASS both times; `build/bench/measure-first.json` has `projectedPR_s` ≤ 600 and `variance` ≤ 0.05. Planning measured 576 s and 0.0013 (P5).

- [ ] **Step 6: STOP GATE.** If either expectation fails, or if the runner exits early twice, **stop and present** to the user:
  - (a) the PR bench runs only the Basic profile;
  - (b) 6 clips per run line;
  - (c) MT-only drops to 100 sentences per direction (already proposed in P5);
  - for variance > 5 %: (d) gate latency on the full tier only, with thresholds widened to 3 × the measured variance.

  Continue only with the user's choice.

- [ ] **Step 7: Commit**

```bash
git add TranslateCallTests/Support/TestTier.swift TranslateCallTests/Support/Tags.swift TranslateCallTests/TestPlans/Bench.xctestplan \
  TranslateCall.xcodeproj/xcshareddata/xcschemes/TranslateCall.xcscheme TranslateCallTests/Bench
git commit -m "test(bench): bench tier and measure-first gate (M9 design §3.6)"
```

---

### Task 2: `PipelineTracer` — order-based correlation, signposts (REQ-BH-10…13) — **opus review (audio path)**

**Files:**
- Create: `TranslateCall/Core/Trace/TraceEvent.swift`, `TranslateCall/Core/Trace/PipelineTracer.swift`
- Create: `TranslateCallTests/Support/CollectingTraceSink.swift`, `TranslateCallTests/PipelineTracerTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated enum TraceDirection: String, Sendable, Codable { case outgoing, incoming }`
  - `nonisolated enum TraceStage: String, Sendable, Codable { case speechStart, vadEnd, sttFinal, translated, ttsFirstBuffer, ttsEnd, dropped }`
  - `nonisolated struct TraceEvent: Sendable, Equatable { direction; seq: Int; stage; time: ContinuousClock.Instant; detail: [String: String] }`
  - `nonisolated protocol TraceSink: Sendable { func record(_ event: TraceEvent) }`, `struct NoopTraceSink`
  - `nonisolated final class PipelineTracer: Sendable` with:
    - `init(direction:sink:trailingSilence: Duration, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, originDate: Date = Date())`
    - `var openSeqs: [Int]`
    - `segmentClosed(capturedAt: Date, audioSeconds: Double)`
    - `transcribed(capturedAt: Date, text: String, engine: String, confidence: Float)`
    - `translated(source: String, result: String)`, `translationFailed(source: String, error: Error)`
    - `speakRequested(text: String)`
    - `synthesisStarted(text: String, engine: String)`, `bufferScheduled()`, `synthesisFinished()`
    - `closeOpen(reason: String)`
  - Test support: `final class CollectingTraceSink: TraceSink { var events; func stages(of:) -> [TraceStage]; func event(_ seq:_ stage:) -> TraceEvent? }`

**Rules** (the doc comment on the class states them):
- **Synchronous and `Mutex`-guarded.** Callers never await, and only in-flight utterances are kept (an ended one is removed), so memory stays bounded (REQ-BH-11).
- **`segmentClosed`:**
  - assigns the next seq;
  - emits `speechStart` at `originInstant + capturedAt − originDate`;
  - emits `vadEnd` now with detail `segmentAudioMs` and `trailingSilenceMs` (design §2.3, from the main thread);
  - begins the signpost interval `"Utterance"`.
- **`transcribed`:**
  - matches the open utterance with the same `capturedAt`;
  - drops older ones with no transcript as `dropped(reason: "stt-empty")`;
  - an empty text ends the utterance as `dropped(reason: "empty-text")`.
- **`translated`, `translationFailed` and `speakRequested`** match the oldest open utterance by text. A failure is `dropped(reason: "translate-<error>")`.
- **`synthesisStarted(text)`:**
  - The same text as the current attempt, with nothing heard yet, is a fallback retry: keep the attempt and clear `finished`.
  - Otherwise, any unheard seqs of the previous attempt are `dropped(reason: "tts-no-audio")`. Then it takes the oldest spoken, unattempted utterances whose translations joined by `" "` equal `text`; if no prefix matches, only the oldest.
- **`bufferScheduled`:**
  - the attempt's unheard seqs get `ttsFirstBuffer`, with detail `engine` (the attempt's engine; a fallback retry updates it) and `mergedSeqs` `"0,1"` when there are more than one;
  - if the attempt already `finished`, its seqs end with `ttsEnd`.
- **`synthesisFinished`:** if every seq of the attempt has been heard, they end with `ttsEnd`; otherwise mark the attempt `finished` and wait for a buffer or a retry.
- **`closeOpen`:** every open seq is `dropped(reason:)`.
- Tests call `synthesisStarted(text:engine:)` with `engine: "x"`.
- **Signposts.** `OSSignposter(subsystem: "com.spbarber.TranslateCall", category: "PipelineTrace")`. Each stage is an `emitEvent("Stage", "<direction> <seq> <stage>")`, and the interval ends when the utterance ends.

- [ ] **Step 1: Write the failing tests** in `TranslateCallTests/PipelineTracerTests.swift`, `@Suite("PipelineTracer") struct PipelineTracerTests`.
  - **Setup:** a `ManualNow` (a `Mutex<Duration>` offset over a fixed origin) injected as `now`, `date0 = Date(timeIntervalSinceReferenceDate: 1_000)` as `originDate`, and `trailingSilence: .milliseconds(600)`.
  - **Tests:**
    - `fullUtteranceInOrder`: the stages of seq 0 are `[.speechStart, .vadEnd, .sttFinal, .translated, .ttsFirstBuffer, .ttsEnd]`, and `openSeqs` is empty.
    - `vadEndCarriesSegmentAndTrailingSilence`: `audioSeconds: 1.5` gives detail `== ["segmentAudioMs": "1500", "trailingSilenceMs": "600"]`.
    - `speechStartMapsTheSegmentDateOntoTheClock`: advance the clock 3 s, create the tracer, use `capturedAt: date0 − 1.5 s`; `speechStart.time == origin + 1 500 ms`.
    - `segmentWithoutTranscriptIsDroppedWhenALaterOneIsTranscribed`: seq 0 is `dropped` with `reason == "stt-empty"`, and seq 1's `sttFinal` text is `"b"`.
    - `emptyTranscriptEndsTheUtterance`: `reason == "empty-text"`, and `openSeqs` is empty.
    - `translationFailureDropsWithTheError`: `reason` has the prefix `"translate-"`.
    - `mergedSynthesisStampsEveryUtterance`: two spoken utterances `"ONE"`, `"TWO"`, then `synthesisStarted(text: "ONE TWO")` and `bufferScheduled()`; both carry `mergedSeqs == "0,1"`.
    - `fallbackRetryOnTheSameTextKeepsTheAttempt`: start, finish (no audio), start with the same text, then a buffer and a finish; the stages end `[.ttsFirstBuffer, .ttsEnd]`.
    - `bufferScheduledAfterTheSynthesizerFinishedStillCounts`: start, finish, then a buffer; the stages end `[.ttsFirstBuffer, .ttsEnd]` (Review Focus).
    - `closeOpenDropsWhatIsLeft`: `reason == "idle-timeout"`.
    - `overheadPerEventIsUnder50Microseconds`: 2 000 utterances × 5 events through a `NoopTraceSink`; `start.duration(to: .now) / 10_000 < .microseconds(50)` (REQ-BH-12).

- [ ] **Step 2: Run them and watch them fail** (they will not compile).

Run: `just test-only PipelineTracerTests`
Expected: build error: `PipelineTracer` not found.

- [ ] **Step 3: Implement** `TraceEvent.swift` and `PipelineTracer.swift` as specified above. Keep them under the SwiftLint budgets (the planning replay was 232 lines). Signpost argument lines must stay ≤ 120 characters: wrap the `emitEvent` arguments.

- [ ] **Step 4: Run the tests and lint**

Run: `just test-only PipelineTracerTests && swiftlint lint --strict --quiet TranslateCall/Core/Trace`
Expected: 11 tests pass; no lint output.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/Trace TranslateCallTests/Support/CollectingTraceSink.swift TranslateCallTests/PipelineTracerTests.swift
git commit -m "feat(trace): per-utterance pipeline tracer with signposts (M9 REQ-BH-10…13)"
```

---

### Task 3: Tracing decorators and factory wrappers (design §2.2, P1, P4) — **opus review (audio path)**

**Files:**
- Create: `TranslateCall/Core/Trace/TracingDecorators.swift`, `TranslateCall/Core/Trace/PipelineTracer+Wiring.swift`
- Create: `TranslateCallTests/TracingDecoratorTests.swift`

**Interfaces:**
- Consumes: Task 2's `PipelineTracer`; the protocols `VADService` (actor; `nonisolated speechSegments`, `vadStateEvents`, `engine`), `SpeechRecognizerService` (actor; `nonisolated transcriptionStream`, `locale`; `setLocale`), `TranslationService` (`AnyObject`, MainActor by default), `SynthesisService` (actor; `nonisolated isSpeakingStream`, `ttsEvents`), `UtteranceSynthesizer` (`nonisolated`, `Sendable`) and `AudioOutputting` (`nonisolated`, `Sendable`); and `UtteranceStream.make()`.
- Produces:
  - `actor TracingVADService: VADService { init(wrapping: any VADService, tracer:) }`
  - `actor TracingSTTService: SpeechRecognizerService { init(wrapping:tracer:) }`, which stamps the `engine` as `String(describing: type(of: inner))`
  - `final class TracingTranslationService: TranslationService { init(wrapping:tracer:) }`. `warmUp` is not traced (the probe is not an utterance).
  - `actor TracingSynthesisService: SynthesisService { init(wrapping:tracer:) }`, which calls `speakRequested` before forwarding
  - `nonisolated struct TracingUtteranceSynthesizer: UtteranceSynthesizer { let inner; let tracer }`
  - `nonisolated final class TracingAudioOutput: AudioOutputting, Sendable { init(wrapping:tracer:) }`
  - `@MainActor extension PipelineTracer`:
    - `tracingVAD(_ make: @escaping () async -> any VADService) -> () async -> any VADService`
    - `tracingSTT(_:) -> (Locale) -> any SpeechRecognizerService`
    - `tracing(_ service: any TranslationService) -> any TranslationService`
    - `tracingTTS(_:) -> (Locale, AudioDeviceID?) throws -> any SynthesisService`
    - `tracing(_ synthesizer: any UtteranceSynthesizer) -> any UtteranceSynthesizer`
    - `tracing(_ output: any AudioOutputting) -> any AudioOutputting`

**Behaviour:**
- **VAD and STT decorators** own an output stream. `activate` activates the inner service first, then starts a `Task` that iterates the inner stream, calls the tracer and re-yields. `deactivate` awaits the inner `deactivate()`, cancels the task and finishes the output stream. The inner VAD and STT streams never finish on their own.
- **`TracingUtteranceSynthesizer.synthesize`** calls `synthesisStarted(text:engine: inner.engine.rawValue)`, then forwards the inner stream through `UtteranceStream.make()` in a `Task`. It calls `synthesisFinished()` when the inner stream ends, normally or by throwing. `onTermination` cancels the forwarding task.
- **`TracingAudioOutput.schedule`** schedules on the inner output, then calls `bufferScheduled()`.

- [ ] **Step 1: Write the failing tests** in `TranslateCallTests/TracingDecoratorTests.swift`, `@Suite("Tracing decorators") @MainActor`, with a `CollectingTraceSink`.
  - **`vadForwardsSegmentsAndStampsThem`:**
    - Setup: `MockVADService(engine: .silero)` wrapped; activate with a finished stream; then `inner.injectSpeechSegment(SpeechSegment(audio: makePCMBuffer(frames: 16_000), capturedAt: d))`.
    - The wrapped stream yields `capturedAt == d`; the stages are `[.speechStart, .vadEnd]`; `segmentAudioMs == "1000"`; `engine == .silero`; `deactivate` reaches the inner service.
    - Iterate the result with `Task { () -> Date? in … }`: an explicit closure type is needed.
  - **`sttForwardsResultsAndStampsThem`:**
    - Setup: `MockSpeechRecognizerService` and `injectTranscription(TranscriptionResult(text:"hola", confidence:0.9, locale:, capturedAt: d, audioDuration:1))`, after `segmentClosed(capturedAt: d…)`.
    - The text is forwarded, and `detail["engine"] == "MockSpeechRecognizerService"`.
  - **`translationPassesThroughAndStampsSuccessAndFailure`:**
    - Setup: `MockTranslationService` (from `TranslationPipelineTests.swift`) with `errors = [TranslationError.timedOut]`.
    - The first call throws `.timedOut` and seq 0 is `dropped`; the second returns `"TRANSLATED: b"`, and seq 1's `translated` text equals it; `warmUp` is forwarded (`warmUpCalls.count == 1`).
  - **`playbackServiceIsTracedEndToEnd`:**
    - Setup: a real `TTSPlaybackService(primary: tracer.tracing(FakeSynthesizer()), output: tracer.tracing(FakeOutput(autoComplete: true)))`, wrapped in `TracingSynthesisService`, with two translated seqs and `speak("ONE")`, `speak("TWO")`.
    - `await waitUntil { tracer.openSeqs.isEmpty }`; both seqs end `[.ttsFirstBuffer, .ttsEnd]`.

- [ ] **Step 2: Run them and watch them fail**

Run: `just test-only TracingDecoratorTests`
Expected: build error, the decorators are missing.

- [ ] **Step 3: Implement the two files.** `PipelineTracer+Wiring.swift`'s doc comment says the app wraps nothing today (P1). Wrap long signatures so lines stay ≤ 120 characters.

- [ ] **Step 4: Run the tests, the unit tier and lint**

Run: `just test-only TracingDecoratorTests PipelineTracerTests && just test && just lint`
Expected: everything passes. The unit tier is unchanged apart from the new suites (NFR-BH-04).

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/Trace TranslateCallTests/TracingDecoratorTests.swift
git commit -m "feat(trace): pass-through tracing decorators and factory wrappers (M9 design §2.2)"
```

---

### Task 4: Swift side of the data contracts — manifest reader, `raw.json` schema 1, golden samples

**Files:**
- Create: `TranslateCallTests/Bench/BenchModels.swift`, `TranslateCallTests/Bench/BenchModelsTests.swift`
- Create: `tools/bench/tests/fixtures/manifest-v1-sample.json` (hand-written, 3 clips and 2 MT sentences, valid schema 1)
- Create: `tools/bench/tests/fixtures/raw-v1-sample.json` (generated by the Swift test in Step 3, then committed)

**Interfaces:**
- Consumes: `TraceEvent` (Task 2).
- Produces (Python Tasks 8 and 9 read and write the same shapes):
  - `struct BenchManifest: Decodable`, with:
    - `schema: Int`, `clips: [Clip]`, `mtOnly: [MTSentence]`;
    - `Clip { id, lang, variant, audio /* path relative to the cache */, speechStartMs: Double, speechEndMs: Double, tiers: [String], sha256 }`;
    - `MTSentence { id, srcLang, tgtLang, src, tiers }`;
    - `func clips(variant:set:)`, `func mtOnly(from:to:set:)`.

    The manifest has more fields (transcript, translations, speaker, licence…); Swift ignores them.
  - `struct RawRun: Codable, Equatable`, with:
    - `schema = 1`, `runId`, `set`, `profile`, `runLine`, `informative: Bool`, `override: String?`;
    - `meta: Meta { commit, dirty, machine, macOS, xcode, manifestSha256, engines: [String: String], settings: [String: String] }`;
    - `clips: [Clip { id, feedStartNs, feedEndNs, speechStartNs, speechEndNs: Int64 }]`;
    - `utterances: [Utterance { seq, events: [String: Int64], detail: [String: [String: String]], audio: String? }]`;
    - `mtOnly: [MTResult { id, hyp: String?, error: String?, ms: Double }]`.
  - `static func RawRun.Utterance.from(_ events: [TraceEvent], origin: ContinuousClock.Instant, audio: (Int) -> String?) -> [RawRun.Utterance]` (grouped by seq, sorted)
  - `ContinuousClock.Instant.nanoseconds(to:) -> Int64`
  - `BenchJSON.encoder()` with `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`

`BenchModelsTests` has no tier gate: it is pure Codable and runs in the unit tier.

- [ ] **Step 1: Write the failing tests** in `BenchModelsTests.swift`, `@Suite("Bench models")`:
  - `manifestSampleDecodes`: decode `tools/bench/tests/fixtures/manifest-v1-sample.json`, located from `#filePath` (four levels up gives the repo root). Expect `schema == 1`, `clips(variant: "es-ES", set: "pr").count == 1`, `mtOnly(from: "en", to: "es", set: "pr").count == 1`.
  - `utterancesGroupBySeqAsNanosecondOffsets`: events for seqs 1 and 0 at origin + 5 ms and + 7 ms. Expect `from(...)` to be sorted by seq, with `events["vadEnd"] == 5_000_000` and `detail["vadEnd"]?["trailingSilenceMs"] == "600"`.
  - `rawSampleIsStable`: build a fixed `RawRun` (2 clips, 2 utterances, 1 MT result, fixed meta), encode it with `BenchJSON.encoder()`, and compare the bytes with `raw-v1-sample.json`. If the env var `TC_WRITE_GOLDEN=1` is set, write the file instead and record an issue telling the user to commit it.

- [ ] **Step 2: Run them; they fail to compile.** `just test-only BenchModelsTests`.

- [ ] **Step 3: Implement `BenchModels.swift`.** Run once with `TC_WRITE_GOLDEN=1` (`TEST_RUNNER_TC_WRITE_GOLDEN=1 just test-only BenchModelsTests`) to create `raw-v1-sample.json`, then run again without it.

Expected: 3 tests pass.

- [ ] **Step 4: Commit**

```bash
git add TranslateCallTests/Bench/BenchModels*.swift tools/bench/tests/fixtures
git commit -m "test(bench): manifest and raw.json v1 contracts with golden samples"
```

---

### Task 5: Bench session — file-backed system capture, profiles, tracing, isolation (REQ-BH-20, 24, 25, 30–34) — **opus review**

**Files:**
- Create: `TranslateCallTests/Bench/BenchSystemAudioCapture.swift`
- Modify: `TranslateCallTests/Bench/BenchPipelineFactory.swift`. Replace `makeBasic` and `ScheduleLog` with the API below, and switch `MeasureFirstTests` to `make` + `start` with `session.output`.
- Create: `TranslateCallTests/Integration/BenchSmokeTests.swift` (integration tier: keeps the bench path alive in `just pr`, design §8)

**Interfaces:**
- Consumes:
  - Task 1's player;
  - Task 3's wrappers;
  - `STTEngineSelector.setPreferredEngine`, `.parakeetAvailable`, `.whisperAvailable`, `.usingFallback`, `.preferredEngine`;
  - from `TTSEngineSelector`:
    - `.setPreferredEngine`, `.voiceCloningEnabled`, `.activeVoiceProfileId`, `.setProfileStore`, `.voiceCloneAvailable`, `.voiceCloningActive`;
    - the `var` factories `outputFactory`, `avSpeechFactory`, `kokoroFactory`, `voiceCloneFactory`, `edgeFactory`;
  - `QwenCloneModelManager.shared.ensureReady()`, `VoiceProfileStore()`;
  - `SystemAudioCapture` (actor; `requestPermissionAndLoadApps`, `activate(target:)`, `deactivate`, `nonisolated events`), `CaptureTarget.app(bundleID:)`;
  - `AudioCoordinator.incomingStatus`, `.errorAlert` (`AlertItem.title`/`.message`).
- Produces (used by T6):
  - `actor BenchSystemAudioCapture: SystemAudioCapture { nonisolated let player: BenchClipPlayer }`
  - `enum BenchProfile: String, CaseIterable { case basic, best }`
  - `struct BenchOptions { profile = .basic; edge = false; overrideSTT: STTEngine?; overrideTTS: TTSEngine? }`
  - `final class BenchOutput: AudioOutputting, Sendable { var scheduleTimes; func drain() -> [(ContinuousClock.Instant, AVAudioPCMBuffer)] }`
  - `@MainActor final class BenchSession { line, coordinator, mic, system, vads, stt, tts, host, sink: CollectingTraceSink, tracer /* the measured direction's */, output: BenchOutput, origin: ContinuousClock.Instant; var player: BenchClipPlayer; func tearDown() async /* stop, tracer.closeOpen("session-stop"), close host, remove suite */ }`
  - `BenchRunLine.direction: TraceDirection`
  - `@MainActor enum BenchPipelineFactory { static func make(_ line: BenchRunLine, options: BenchOptions, vadProvider: VADProvider = VADProvider()) async throws -> BenchSession; static func start(_ session: BenchSession, options: BenchOptions) async throws }`

- [ ] **Step 1: Write the failing smoke tests** in `extension IntegrationTests { @Suite("Bench smoke") @MainActor struct BenchSmokeTests }`:
  - `tracedSessionProducesCompleteTraces`:
    - Basic, `.outgoingEsESToEn`; `make`, then `start`.
    - Play the `es-greeting` and `es-meeting` fixtures, each followed by `playSilence(1.5)`.
    - Then `await waitUntil(timeout: .seconds(20)) { session.tracer.openSeqs.isEmpty }`.
    - Each seq in `session.sink.events` with a `.vadEnd` has the stages `speechStart, vadEnd, sttFinal, translated, ttsFirstBuffer, ttsEnd`, in that order; at least 2 seqs.
    - `tearDown()`.
  - `userDefaultsUntouched`: snapshot `UserDefaults.standard.dictionaryRepresentation()` filtered to keys with the prefixes `tlk.` and `conversation.` before `make`, and again after `tearDown`; they are equal (NFR-BH-03).
  - `startRefusesEnergyVAD`:
    - Call `make(…, vadProvider: VADProvider(loadSilero: { _ in throw BenchSetupError(description: "no silero") }))`.
    - `start` throws `MissingPrerequisite`, and the issue names "Silero VAD".
    - Wrap the test in `withKnownIssue` for the recorded issue only.

- [ ] **Step 2: Run them and watch them fail.** Use the integration command with `-only-testing:TranslateCallTests/IntegrationTests/BenchSmokeTests`. It fails to compile.

- [ ] **Step 3: Implement.**
  - **`BenchSystemAudioCapture`:**
    - `activate` returns `player.start()` and `deactivate` calls `player.stop()`;
    - `events` is a stream that never yields;
    - `requestPermissionAndLoadApps` returns `[]`.
  - **`BenchPipelineFactory.make`**, built as in Task 1 plus the following:
    - **Tracers.** Two `PipelineTracer`s on one `CollectingTraceSink`, with `trailingSilence: .seconds(settings.vadConfiguration.minSilenceDuration)`.
    - **Wrapping.** `outgoingVADFactory: outTracer.tracingVAD { await vads.makeVAD(config: vadConfig) }`, and the same for STT and translation in both directions.
    - **TTS factories:**
      ```swift
      outgoingTTSFactory: { locale, device in
          try traced(tts, outTracer, output: output) { try tts.makeOutgoingService(for: locale, deviceID: device) }
      },
      ```
      `traced` saves the five selector factories, sets `outputFactory = { _ in tracer.tracing(output) }`, wraps each synthesizer factory with `tracer.tracing(...)`, builds, restores everything in a `defer`, and returns `TracingSynthesisService(wrapping:tracer:)` (P4).
    - **STT selector (REQ-BH-30/31/34):**
      - The engine is `overrideSTT ?? (best ? .parakeet : .appleSpeech)`; call `setPreferredEngine`.
      - Parakeet: `waitUntil(timeout: .seconds(120)) { stt.parakeetAvailable }`, or else `requirePrerequisite` fails with "Parakeet model (download it in the app: STT → Parakeet)".
      - Whisper: the same, with 300 s.
    - **TTS selector.** `edge` means `setPreferredEngine(.edgeTTS)`; an override means `setPreferredEngine(engine)`. For Best without edge or an override:
      - read the UUID string `UserDefaults.standard.string(forKey: "tlk.voiceCloning.activeProfileId")` (read only), and require it, naming "an active voice-clone profile (M5)";
      - `activeVoiceProfileId = id`, `setProfileStore(VoiceProfileStore())`, `voiceCloningEnabled = true` (this writes to the throwaway suite);
      - `try await QwenCloneModelManager.shared.ensureReady()`, then wait 120 s for `voiceCloneAvailable`.
    - **Host window.** **P6: after the rebase, call `host.show()` right after creating the `TranslationHostWindow`.**
  - **`start`:**
    - `coordinator.start(captureTarget: line.incoming ? .app(bundleID: "bench") : nil)`;
    - require, each with its own message:
      - `isOutgoingActive`, the message including the alert title and message;
      - for incoming, `incomingStatus == .active`;
      - `vads.activeEngine == .silero`;
      - `!stt.usingFallback`;
      - for Best outgoing with no edge or override, `tts.voiceCloningActive`.

- [ ] **Step 4: Run the smoke suite twice, then the gate once more** (it now uses `make`/`start`).

Expected: 3 smoke tests pass both times; the gate still passes.

- [ ] **Step 5: Commit**

```bash
git add TranslateCallTests/Bench TranslateCallTests/Integration/BenchSmokeTests.swift
git commit -m "test(bench): traced bench session with profiles and isolation checks (M9 REQ-BH-20…34)"
```

---

### Task 6: Bench runner — run lines × profiles, idle wait, MT-only, `raw.json` (REQ-BH-21…23, 32, 39, 50)

**Files:**
- Create: `TranslateCallTests/Bench/BenchRunner.swift`, `TranslateCallTests/Bench/BenchRunLineTests.swift`
- Delete: `TranslateCallTests/Bench/MeasureFirstTests.swift` (the gate's job is done; its numbers are in P5)

**Interfaces:**
- Consumes: T4's models, T5's session.
- Produces:
  - `struct BenchEnvironment { set: String /* "pr"|"full" */; profiles: [BenchProfile]; edge: Bool; overrideSTT: STTEngine?; overrideTTS: TTSEngine?; cache: URL; out: URL; manifest: URL; commit: String; dirty: Bool; static func current() throws -> BenchEnvironment }`. It reads `TC_BENCH_SET`, `TC_BENCH_PROFILE` (`basic|best|all`), `TC_BENCH_EDGE`, `TC_BENCH_OVERRIDE_STT`, `TC_BENCH_OVERRIDE_TTS`, `TC_BENCH_CACHE` (default `~/Library/Caches/TranslateCallBench`), `TC_BENCH_OUT`, `TC_BENCH_MANIFEST` (default `bench/manifests/phase1.json`), `TC_COMMIT` and `TC_DIRTY`. A missing `TC_BENCH_OUT` fails with "run through `just bench`".
  - `@MainActor enum BenchRunner { static func run(_ line: BenchRunLine, profile: BenchProfile, env: BenchEnvironment) async throws -> URL /* raw.json path */ }`

**Behaviour:**
- **Before the session.** `run` skips (returns, without failing) Best × `incomingEnToEs`, because those engines are the Basic ones (design §3.6).
- **Session start.** `make` and `start`, then `playSilence(2)`.
- **MT-only first.** Use the pair of the line: outgoing translates `userLanguage → otherLanguage`, incoming the reverse. For each `manifest.mtOnly(from:to:set:)` sentence, call `session.coordinator.outgoingTranslationService.translate` (or the incoming one). It is untraced: the wrapper only matches traced utterances. Time each call, and record a thrown error in `error`.
- **Clips.** For each `manifest.clips(variant: line.variant, set: env.set)`:
  - check the `sha256` of the cached file (`CryptoKit.SHA256`), failing with the clip id on a mismatch;
  - decode it, and `feed = await session.player.play(samples)`;
  - `speechStart`/`speechEnd = feed.instant(ofSample: Int(ms × 16))`;
  - **idle wait (REQ-BH-21):** keep playing 100 ms silence slices until `session.tracer.openSeqs.isEmpty` and at least `pause + 0.5 s` has passed since `feed.end`, or 15 s have passed;
  - on a timeout, `session.tracer.closeOpen(reason: "idle-timeout")`;
  - then `playSilence(0.5)`;
  - `session.output.drain()` goes to `audio/<seq>.wav` (16-bit PCM at the buffer's rate) for each seq whose `ttsFirstBuffer`…`ttsEnd` window holds the buffer instant (P10).
- **Write the record.**
  - Location: `<out>/<profile>/<runLine slug>/raw.json` with `BenchJSON.encoder()`.
  - Utterances come from `RawRun.Utterance.from(session.sink.events.filter { $0.direction == line.direction }, origin: session.origin, …)`.
  - `meta` holds:
    - the commit and dirty flag from the environment;
    - `machine` from `sysctlbyname("hw.model")`;
    - `macOS` from `ProcessInfo.operatingSystemVersionString`;
    - `xcode` from `TC_XCODE`, which `bench.sh` sets;
    - the manifest sha256;
    - `engines`: `vad`, `stt` (the `engine` detail of the first `sttFinal`), `sttLocale` (P8), `translation` (`engineName`), `tts` (the `engine` detail of the first `ttsFirstBuffer`).
    - `settings`: `pauseSeconds`, `vadChunkSamples` (`4096`), `listeningMode`.
  - `informative = env.edge`, and `override` = `"stt=…,tts=…"` or nil.
- **Tests.** `BenchRunLineTests` (in `extension BenchTests`) has one `@Test` per line × profile: `outgoing_esES_en_basic()`, `outgoing_esES_en_best()`, `outgoing_es419_en_basic()`, `outgoing_es419_en_best()`, `outgoing_en_es_basic()`, `outgoing_en_es_best()`, `incoming_en_es_basic()`. Each one:
  - skips (with `.enabled(if:)`) when its profile is not in `env.profiles`;
  - fails when its variant has 0 clips in the set: "no clips for es-ES in set pr — run `just bench-fetch`".

- [ ] **Step 1: Write `BenchEnvironment` unit coverage** in `BenchModelsTests` (unit tier). `BenchEnvironment.parse(_ env: [String: String])` is the pure core of `current()`. Test: the defaults, `profile=all` → `[.basic, .best]`, `TC_BENCH_OVERRIDE_STT=parakeet` → `.parakeet`, and a missing `TC_BENCH_OUT` throws.
- [ ] **Step 2: Run them (they fail), implement `BenchEnvironment.parse`, and run them (they pass).** `just test-only BenchModelsTests`.
- [ ] **Step 3: Implement `BenchRunner` and `BenchRunLineTests`, and delete `MeasureFirstTests`.**
- [ ] **Step 4: Bench smoke run** against the golden manifest sample and two real FLEURS clips. Place them in the cache by hand: `uv run --project tools/bench tcbench fetch --set pr --limit 2` exists only after Task 8, so before that copy two `say` fixtures into the cache under the sample manifest's paths and sha256.

Run: `TEST_RUNNER_TC_BENCH_OUT=build/bench/runs/dev TEST_RUNNER_TC_BENCH_MANIFEST=tools/bench/tests/fixtures/manifest-v1-sample.json TEST_RUNNER_TC_BENCH_PROFILE=basic` followed by the bench command with `-only-testing:TranslateCallTests/BenchTests/BenchRunLineTests/outgoing_esES_en_basic()`.
Expected: PASS. `build/bench/runs/dev/basic/outgoing-es-ES-en/raw.json` exists and has 1 clip and ≥ 1 utterance with all six stages. If the runner exits early (P5), record it in this file's "Found while executing" section and rerun.

- [ ] **Step 5: Commit**

```bash
git add TranslateCallTests/Bench
git commit -m "test(bench): run lines × profiles writing raw.json v1 (M9 REQ-BH-21…23, 50)"
```

---

### Task 7: Python package skeleton — `uv`, WER port, statistics, CI (REQ-BH-36, 62)

**Files:**
- Create: `tools/bench/pyproject.toml`, `tools/bench/uv.lock`, `tools/bench/tcbench/{__init__,cli,text,stats}.py`, `tools/bench/tests/{test_text,test_stats}.py`
- Modify:
  - `tools/versions.env`: add `UV_VERSION=0.9.x`, pinning the exact current release at execution time. Bump `XCODE_VERSION=27.1` if the UI PR hasn't.
  - `tools/scripts/setup.sh`: install `uv` (`brew install uv`), check the pinned version, run `uv sync --project tools/bench`. In `--ci` mode only install `uv` via the official installer with the pinned version.
  - `justfile` recipe `check`: add `test-bench-tools` → `uv run --project tools/bench pytest -q`.
  - `.github/workflows/check.yml`: a step "Bench tooling tests" running `astral-sh/setup-uv@v6` with `version: ${UV_VERSION}`, then `uv run --project tools/bench pytest -q`.
  - `.gitignore`: `tools/bench/.venv/`, `.pytest_cache/`, `__pycache__/`.

**Interfaces:**
- Produces:
  - `tcbench.text.normalize_words(text: str) -> list[str]`, the port of `WordErrorRate.words`:
    - NFKD, then drop combining marks, casefold;
    - split on any character that is not Unicode alphanumeric (`str.isalnum()`), dropping empties.
  - `tcbench.text.wer(reference: str, hypothesis: str) -> float`: an empty reference gives `0` if the hypothesis is empty, else `1`.
  - `tcbench.text.corpus_wer(pairs: list[tuple[str, str]]) -> float`: total edits over total reference words.
  - `tcbench.stats.summary(values: list[float]) -> dict`, with keys `p50`, `p90`, `mean`, `count`, using numpy `percentile` with `method="linear"`; `None` values when empty.
  - CLI `tcbench` (argparse) with subcommands `fetch`, `manifest`, `ingest`, `analyze`, `compare`, `report` and `baseline`. Stubs exit 2 with "not implemented" until their task.

- [ ] **Step 1: Write the failing tests.** `tests/test_text.py` holds the five Swift cases from `TranslateCallTests/Support/WordErrorRateTests.swift`, with the same strings and expected values:
  - `"hola qué tal"` == 0;
  - `"Hola, ¿qué tal?"` vs `"hola que tal"` == 0;
  - `"can you hear me"` vs `"can you see me"` == 0.25;
  - the Ukrainian 2/3 case, `abs(x − 2/3) < 1e-9`;
  - `"a b"` vs `""` == 1;
  - plus `corpus_wer([("a b", "a"), ("c d", "c d")]) == 0.25`.

  `tests/test_stats.py` checks `summary([1,2,3,4])` gives p50 2.5, p90 3.7, mean 2.5, count 4; and that `summary([])` has count 0 and `None` values.
- [ ] **Step 2: Run them; they fail.** `uv run --project tools/bench pytest -q` gives ModuleNotFoundError.
- [ ] **Step 3: Implement.** Pin the Python dependency versions in `pyproject.toml` (`requires-python = ">=3.12,<3.13"`); `comet` is an optional extra.
- [ ] **Step 4: Run the tests, then `just check`.** Expected: all pass, and the lint, scan and tooling self-tests are unchanged.
- [ ] **Step 5: Commit**: `git commit -m "build(bench): tcbench package skeleton with WER port and CI step"`

---

### Task 8: `tcbench fetch` and `tcbench manifest` — sources, licences, ground truth (REQ-BH-01…08, NFR-BH-05)

**Files:**
- Create: `tools/bench/tcbench/{sources,groundtruth,manifest,fetch,audio}.py`, `tools/bench/tests/{test_groundtruth,test_manifest,test_fetch}.py`
- Create: `bench/licences.json`, `bench/manifests/phase1.json` (generated by `just bench-manifest`, then committed)

**Interfaces:**
- Consumes: the schema of `tools/bench/tests/fixtures/manifest-v1-sample.json` (Task 4).
- Produces:
  - `groundtruth.speech_span(samples: np.ndarray, sr: int = 16000) -> tuple[float, float] | None`, returning (start_ms, end_ms):
    - Silero (`silero-vad`, 512-sample windows, threshold 0.35) gives the span;
    - each edge is moved, in 10 ms hops, to the last frame whose RMS is within 25 dB of the clip's peak RMS;
    - `None` when the two methods disagree by more than 150 ms on either edge.
  - `audio.normalize(path_or_bytes) -> np.ndarray`: 16 kHz mono float32 (soundfile + soxr).
  - `audio.write_wav16(path, samples)`: 16-bit PCM WAV; `audio.sha256(path)`.
  - `manifest.build(sources_cfg, seed=1729) -> dict` (schema 1, deterministic), `manifest.dump(m, path)` (sorted keys, indent 2, `ensure_ascii=False`, trailing newline).
  - `fetch.run(manifest_path, cache_dir, set_name, limit=None)`: idempotent, verifies `sha256`, and exits non-zero naming the clip or source.
  - The per-source selection rules and pinned revisions are those of design §4.1:
    - **FLEURS:** `google/fleurs`, configs `es_419` and `en_us`, test split. Only ids present in both; 2–12 s; 300 full; 8 per run line in PR, chosen ≤ 6 s.
    - **VoxPopuli:** `facebook/voxpopuli` `es` test → `es-ES`.
    - **Smart Turn v3 test:** `pipecat-ai/smart-turn-data-v3-test`, rows `spa`/`eng`, balanced; full only. Spanish is `es-xx`.
    - **NTREX-128:** pinned git commit. 200 sentences per direction in full, **100 in PR (P5)**, seed 1729.
    - **Common Voice:** only when `TC_BENCH_CV_TOKEN` is set, with a clear skip message otherwise.

    `huggingface_hub` revisions are pinned in `sources.py` as commit SHAs, resolved once at execution time and written as constants.
- **Manifest entry fields:** every field of REQ-BH-01, plus `audio`, the cache-relative path `"<dataset>/<variant>/<id>.wav"`.

- [ ] **Step 1: Write the failing tests.**
  - `test_groundtruth`:
    - a synthetic clip of 0.5 s silence + 1.0 s 220 Hz tone at −12 dBFS + 0.7 s silence: start ≈ 500 ± 20 ms, end ≈ 1500 ± 20 ms;
    - an all-silence clip gives `None`.
    - Silero needs a model download, so the test monkeypatches the Silero call with a stub returning the tone span; the real Silero runs in `test_groundtruth_silero_real`, marked `@pytest.mark.network` and excluded on CI.
  - `test_manifest`:
    - `build` twice on a stub source → identical `dump` bytes;
    - `es-ES` and `es-419` never share a clip;
    - a source with licence `CC-BY-NC-4.0` → `ValueError` naming the source;
    - every entry has all REQ-BH-01 fields.
  - `test_fetch`: in a `tmp_path` cache, fetching twice performs no download the second time, and a corrupted file → exit 1 with the clip id in stderr.
- [ ] **Step 2: Run them; they fail.**
- [ ] **Step 3: Implement**, write `bench/licences.json` (id, licence SPDX, url, attribution text), and generate `bench/manifests/phase1.json` with `uv run --project tools/bench tcbench manifest`.
- [ ] **Step 4: Run `pytest` (offline tests), then `tcbench fetch --set pr`.** Expected: the PR download is under 150 MB (REQ-BH-07), checked with `du -sh` on the cache; a second fetch prints "up to date".
- [ ] **Step 5: Commit**, including `bench/manifests/phase1.json` and `bench/licences.json`, but no audio: `git commit -m "feat(bench): dataset fetch and deterministic phase-1 manifest (M9 REQ-BH-01…08)"`

---

### Task 9: `tcbench analyze` — assignment, latency, WER, cuts, chrF++, COMET (REQ-BH-22, 35–38; P2)

**Files:**
- Create: `tools/bench/tcbench/analyze.py`, `tools/bench/tests/test_analyze.py`

**Interfaces:**
- Consumes: `raw.json` v1 (the Task 4 sample), the manifest, and `text`/`stats` (Task 7).
- Produces: `analyze.run(run_dir: Path, manifest: dict, comet: bool) -> dict`, which writes `metrics.json` next to each `raw.json`, plus an aggregate `<run>/metrics.json` keyed `"<profile>/<runLine>"`, with:
  - `latency: {stage: summary}` for `vad`, `stt`, `translate`, `ttsFirstAudio` and `total`; and `latencyCold`;
  - `wer`; `cutRate`; `mergeRate`; `missed`; `dropped: {reason: count}`;
  - `chrf: {pipeline, mtOnly}`; `comet: {…} | None`.

**Rules:**
- **Assignment.** A seq belongs to the clip whose window `[feedStartNs, next clip's feedStartNs)` holds its `speechStart`. A seq whose `speechStart + segmentAudioMs` passes the next clip's `speechStartNs` is a **merge**. A clip with no seq is **missed**.
- **Latency:**
  - only on the clip's last seq;
  - `vad = vadEnd − speechEndNs`, `stt = sttFinal − vadEnd`, `translate = translated − sttFinal`, `ttsFirstAudio = ttsFirstBuffer − translated`, `total = ttsFirstBuffer − speechEndNs`;
  - all in ms;
  - the run's first seq is `cold`.
- **WER:** corpus WER of each clip's seqs' `sttFinal` texts, joined, against the manifest transcript.
- **Cut rate:** (clips with more than one seq + Smart Turn `incomplete` clips whose first `vadEnd` < `speechEndNs`) / (clips + Smart Turn incomplete clips).
- **chrF++:** `sacrebleu.CHRF(word_order=2)`. "Pipeline" uses the joined translations against the manifest reference translation; "mtOnly" uses `mtOnly.hyp` against the manifest reference.
- **COMET:** only with `comet=True`, `Unbabel/wmt22-comet-da` at the pinned revision.

- [ ] **Step 1: Write the failing tests** on synthetic `raw.json` dictionaries:
  - `test_assignment_by_feed_window`.
  - `test_cut_clip_latency_on_last_seq` (Review Focus): a clip with seqs 3 and 4. `cutRate == 1/1`, and total uses seq 4's `ttsFirstBuffer`.
  - `test_merge_counted`.
  - `test_missed_clip`.
  - `test_wer_joins_seqs`.
  - `test_cold_reported_apart`.
  - `test_chrf_on_sample` (on the Task 4 golden sample: the value is pinned after the first implementation, to 2 decimals).
  - `test_dropped_reasons_counted`.
- [ ] **Step 2: Run them; they fail. Step 3: Implement. Step 4: Run them; they pass.** Then `tcbench analyze build/bench/runs/dev` on the Task 6 smoke output, and check that `metrics.json` exists.
- [ ] **Step 5: Commit**: `git commit -m "feat(bench): metrics from raw.json — latency, WER, cuts, chrF++, COMET (M9 REQ-BH-35…38)"`

---

### Task 10: `tcbench compare` and `tcbench baseline` (REQ-BH-51, 52, 54)

**Files:**
- Create: `tools/bench/tcbench/{compare,baseline}.py`, `tools/bench/tests/{test_compare,test_baseline}.py`, `bench/thresholds.json`

**Interfaces:**
- `bench/thresholds.json`:
  ```json
  {"latencyP50RegressionPct": 10, "latencyP90RegressionPct": 15,
   "werIncreasePts": 2.0, "chrfDropPts": 2.0, "cutRateMaxPct": 5, "cutRateIncreasePts": 2.0}
  ```
- `compare.run(run_metrics: dict, baseline: dict, thresholds: dict, run_meta: dict) -> tuple[str, int]`, returning (table text, exit code):
  - one row per `profile/runLine` × metric (total p50/p90, WER, cut rate, chrF++ pipeline and MT-only, COMET if present), each with baseline, value, delta and ✅/❌;
  - latency rows are gated only when `set == "full"`, and show `·` otherwise;
  - the cut-rate verdict ❌ when the value exceeds `max(cutRateMaxPct, baseline + cutRateIncreasePts)`;
  - exit 1 on any gated ❌;
  - **refuses** (exit 3, with "manifest changed — re-baseline with `just bench-baseline`") when `manifestSha256` differs;
  - **warns** when the `macOS` build differs;
  - informative or overridden runs are compared but never gate (exit 0, with a banner).
- CLI: `tcbench compare <run> [--baseline bench/baseline.json | --baseline-from-run <run>]`; the second form builds an in-memory baseline from another run's aggregates (Task 16's reproducibility check).
- `baseline.run(run_dir, reason: str, repo_dirty: bool) -> None`. It writes `bench/baseline.json` with `{reason, date, commit, manifestSha256, macOS, machine, set, aggregates}`. It refuses a dirty tree, an `informative` run and an `override` run, each with its own message.

- [ ] **Step 1: Write the failing tests:**
  - `test_compare_pass_and_fail_verdicts`: WER +2.1 → ❌ and exit 1; +1.9 → ✅.
  - `test_latency_not_gated_on_pr`.
  - `test_compare_refuses_manifest_mismatch` (Review Focus), exit 3.
  - `test_compare_warns_macos_change` (Review Focus), with "macOS changed" in the output.
  - `test_cut_rate_rule`.
  - `test_baseline_refuses_dirty`, `…_informative`, `…_override`.
  - `test_baseline_roundtrip`.
- [ ] **Step 2: Run them; they fail. Step 3: Implement. Step 4: Run them; they pass.**
- [ ] **Step 5: Commit**: `git commit -m "feat(bench): baseline comparison with ✅/❌ verdicts and re-baseline command (M9 REQ-BH-51…54)"`

---

### Task 11: `tcbench report` — self-contained HTML (REQ-BH-53, NFR-BH-05)

**Files:**
- Create: `tools/bench/tcbench/report.py`, `tools/bench/tcbench/templates/report.html.j2`, `tools/bench/tcbench/vendor/vega-bundle.min.js` (vega@5.30.0 + vega-lite@5.21.0 + vega-embed@6.26.0, downloaded once and committed with their licences), `tools/bench/tests/test_report.py`

**Interfaces:**
- `report.run(run_dir: Path, history_dir: Path, last_n: int = 10) -> Path`. It writes `report.html` in the run directory. The page contains:
  - a header with the metadata;
  - a stacked stage chart per `profile/runLine`;
  - a total-latency histogram;
  - a baseline comparison table (the `compare` table rendered as HTML);
  - a trend of total p50 and WER over the last N runs from `build/bench/runs/*/metrics.json`;
  - the 10 worst by total and the 10 worst by WER, each with `<audio>` for the source clip and the TTS output (base64 Opus via `soundfile`, or WAV when Opus is unavailable, capped so the report stays ≤ 8 MB, dropping audio from the lowest-ranked rows first), plus the reference transcript, STT text, translation and reference translation;
  - a footer with the CC BY attributions from `bench/licences.json`, and the ground-truth note (Silero 32 ms / threshold 0.35 vs production 256 ms / 0.85).

- [ ] **Step 1: Write the failing tests:**
  - `test_report_is_self_contained`: no `http://` or `https://` in `src=`/`href=` attributes, apart from links in the attribution text.
  - `test_report_size_capped`: 30 utterances with 10 s of audio each → ≤ 8 MB.
  - `test_attributions_present`.
- [ ] **Step 2: Run them; they fail. Step 3: Implement. Step 4: Run them; they pass.** Open the report from the Task 6 smoke run in a browser and check it loads offline.
- [ ] **Step 5: Commit**: `git commit -m "feat(bench): self-contained HTML report (M9 REQ-BH-53)"`

---

### Task 12: `tcbench ingest` — the user's own recordings (REQ-BH-41)

**Files:**
- Create: `tools/bench/tcbench/ingest.py`, `tools/bench/tests/test_ingest.py`

**Interfaces:**
- Consumes: the prompt sheets (Task 13 format: a Markdown table with columns `id | purpose | text | reference translation`, and `‖` for pause marks), plus `groundtruth` and `audio` (Task 8).
- Produces: `ingest.run(folder: Path, sheet: Path, variant: str, native: bool, manifest_path: Path) -> list[str]`, which returns the problems found. It:
  - accepts wav/m4a/aiff matched to a prompt `id` by file name;
  - normalises each clip into the cache under `own/<variant>/<id>.wav` and computes the ground truth;
  - finds internal pauses longer than 250 ms and matches them to the `‖` marks, tolerating ±1 mark;
  - flags:
    - clipping (more than 0.1 % of samples with |x| ≥ 0.999);
    - silence only;
    - a speech length outside 0.5–2.0 × (words / 2.5 w/s);
    - prompts with no file;
  - writes or replaces the `own-<variant>-<id>` manifest entries (with `nativeSpeaker`, the tags from `purpose`, `tiers: ["full"]`, plus `"pr"` for the first 8 by id).

- [ ] **Step 1: Write the failing tests** on synthetic WAVs: `test_matches_files_to_prompts`, `test_flags_clipping`, `test_flags_silence`, `test_pause_marks_matched`, `test_length_ratio_flag`, `test_missing_prompt_reported`.
- [ ] **Step 2: Run them; they fail. Step 3: Implement. Step 4: Run them; they pass.**
- [ ] **Step 5: Commit**: `git commit -m "feat(bench): ingest the user's recordings into the manifest (M9 REQ-BH-41)"`

---

### Task 13: Prompt sheets `bench/prompts/es-ES.md` and `bench/prompts/en.md` (REQ-BH-40)

**Files:**
- Create: `bench/prompts/es-ES.md`, `bench/prompts/en.md`

**Content:**
- **Header:** reading instructions in Spanish for the user:
  - a quiet room, the Mac's built-in mic or a headset;
  - about 1 s of silence before and after each prompt;
  - a natural pace; pause where `‖` appears;
  - file name = id, for example `es-ES-07.m4a`;
  - any recorder (QuickTime, Voice Memos).
- **Then a table** with columns `id | purpose | text | reference translation`, about 40 rows per sheet:
  - **purposes** and counts per sheet:
    - `short` × 8 (1–4 words, for example "Vale, perfecto.");
    - `long` × 8 (20–35 words);
    - `hesitation` × 8 (one or two `‖` marks inside the sentence, for example "Lo que quería decir ‖ es que el presupuesto no da.");
    - `turn-end` × 6 (a sentence that clearly closes a turn);
    - `turn-pause` × 6 (it pauses with `‖` and continues the same thought);
    - `multi-sentence` × 4 (two or three sentences in one turn);
  - **topics:** work calls (meetings, budgets, dates, numbers, names), plus a few casual lines;
  - **`es-ES` text** in Spain Spanish, using vosotros, "ordenador", "vale", "coger"; never Latin American forms;
  - **reference translations** written by Claude, en for the `es-ES` sheet and es-ES for the `en` sheet; the user checks them (manual check M3).

- [ ] **Step 1: Write both sheets.**
- [ ] **Step 2: Validate the format** with `uv run --project tools/bench python -c "from tcbench.ingest import read_sheet; print(len(read_sheet('bench/prompts/es-ES.md')), len(read_sheet('bench/prompts/en.md')))"`. Expected: two numbers of 38–42, and every purpose count as listed. If Task 12 is not done yet, count the table rows with `grep -c '^| es-ES-'`.
- [ ] **Step 3: Commit**: `git commit -m "docs(bench): prompt sheets for the user's es-ES and en recordings (M9 REQ-BH-40)"`

---

### Task 14: `just` recipes, `bench.sh`, and the `just pr` step (REQ-BH-60, 61; NFR-BH-02)

**Files:**
- Create: `tools/scripts/bench.sh`
- Modify:
  - `justfile`: add the recipes below; `test` gains `-skip-testing:TranslateCallTests/BenchTests`; the `test-integration` comment no longer says it writes `latency.json`.
  - `tools/scripts/pr.sh`: the default `TC_PR_STEPS` gains `just bench set=pr profile=all` after `just test-integration`.
  - `tools/scripts/test-pr-gate.sh`: its expected steps list includes the bench step.

**Recipes:**

| Recipe | Command |
|---|---|
| `bench-fetch set="pr"` | `uv run --project tools/bench tcbench fetch --set {{set}}` |
| `bench-manifest` | `uv run --project tools/bench tcbench manifest` |
| `bench-ingest dir variant native="false"` | `uv run --project tools/bench tcbench ingest {{dir}} --variant {{variant}} --native {{native}}` |
| `bench set="pr" profile="all" edge="0"` | `tools/scripts/bench.sh {{set}} {{profile}} {{edge}}` |
| `bench-compare run="latest"` | `uv run --project tools/bench tcbench compare {{run}}` |
| `bench-report run="latest"` | `uv run --project tools/bench tcbench report {{run}}` |
| `bench-baseline run reason` | `uv run --project tools/bench tcbench baseline {{run}} --reason "{{reason}}"` |

**`bench.sh`:**
1. **Prepare.** Fetch the set (idempotent). Print the expected duration: the sum of the set's clip seconds × 1.6, plus MT count × 0.3 s.
2. **Build.** `run_id=$(date -u +%Y-%m-%dT%H-%M-%SZ)-$(git rev-parse --short HEAD)` and `out=build/bench/runs/$run_id`. Run `xcodebuild build-for-testing`.
3. **Run.** `xcodebuild test-without-building -testPlan Bench -only-testing:TranslateCallTests/BenchTests/BenchRunLineTests`, with `TEST_RUNNER_TC_BENCH_SET`, `_PROFILE`, `_EDGE`, `_OUT`, `_CACHE`, `_MANIFEST`, `TEST_RUNNER_TC_COMMIT`, `TEST_RUNNER_TC_DIRTY` and `TEST_RUNNER_TC_XCODE`, and with `-resultBundlePath build/logs/bench.xcresult`.
4. **Analyse.** `tcbench analyze "$out" ${set==full && --comet}`, then `tcbench report "$out"`, then `ln -sfn "$run_id" build/bench/runs/latest`.
5. **Verdict.** `tcbench compare "$out"`, whose exit code is the script's. With no `bench/baseline.json` yet, it prints "no baseline yet" and exits 0.

- [ ] **Step 1:** Extend `tools/scripts/test-pr-gate.sh` so its expected step list includes the bench step, and run it with `just test-tooling`. It should fail first.
- [ ] **Step 2:** Implement the recipes, `bench.sh` and the `pr.sh` change. Run `just test-tooling` and `just check`; they pass.
- [ ] **Step 3:** Run `just bench set=pr profile=basic` end to end. Expected: it finishes in under 6 minutes (Basic only), prints the table with "no baseline yet", and `build/bench/runs/latest/report.html` exists.
- [ ] **Step 4: Commit**: `git commit -m "build(bench): just bench recipes and PR gate step (M9 REQ-BH-60/61)"`

---

### Task 15: Retire `latency.json`; update docs and specs (REQ-BH-50, design §7)

**Files:**
- Delete: `TranslateCallTests/Support/LatencyReport.swift`, `TranslateCallTests/Support/LatencyReportTests.swift`
- Modify: remove `LatencyReport.shared.record(...)` from these files, keeping their assertions and printing the figures with `print("LATENCY …")` instead:
  - `Integration/OutgoingPipelineFixtureTests.swift:43`;
  - `Integration/STTFixtureTests.swift:20-21,31-32`;
  - `Integration/TranslationFixtureTests.swift:35`;
  - `Integration/TranslationBridgeIntegrationTests.swift:40-42,60`;
  - `Integration/SileroSegmentationIntegrationTests.swift:113`;
  - `Integration/TranslationLatencyTests.swift:109-141`.
- Modify:
  - `specs/m8.5-stabilization/f8.5.0-dev-workflow/requirements.md` (REQ-W-24) and `design.md:178`: add "Superseded by M9 benchmark harness (`specs/m9-product/benchmark-harness/`)".
  - `specs/m8.5-stabilization/backlog.md`: A14 is fixed by the M9 harness; T4 and T7 point to the bench for future measurements.
  - `specs/m9-product/benchmark-harness/design.md`:
    - §2.3, first bullet: "the builder wraps the coordinator's factories with `PipelineTracer`'s wrappers (`tasks.md` P1); `AudioCoordinator` is unchanged";
    - §3.4: seq-to-clip assignment lives in `tcbench analyze` (P2);
    - §3.6: the P5 figures.
  - `specs/m9-product/benchmark-harness/requirements.md`:
    - REQ-BH-08: PR 100 / full 200 sentences per direction (if the user accepts P5);
    - Status: APPROVED, with the date.

- [ ] **Step 1:** Delete and edit. Then `grep -rn "LatencyReport\|latency.json" TranslateCallTests tools justfile` gives no output.
- [ ] **Step 2:** `just test`, then the integration suites `OutgoingPipelineFixtureTests`, `STTFixtureTests`, `TranslationFixtureTests`, `TranslationBridgeIntegrationTests`, `SileroSegmentationIntegrationTests` and `TranslationLatencyTests` (the integration command with `-only-testing:` for each). Expected: PASS.
- [ ] **Step 3: Commit**: `git commit -m "refactor(test): retire latency.json in favour of the bench harness (M9 REQ-BH-50)"`

---

### Task 16: First PR-set baseline, the PR gate, and the manual-check handoff

**Preconditions (P7):**
- `main` contains the A27 known-issue wrap for `EdgeTTSIntegrationTests`.
- The branch is rebased on `main` (P6: `host.show()` is in `BenchPipelineFactory.make`).
- The user has done M5: Parakeet downloaded, and a voice-clone profile active.

- [ ] **Step 1:** Run `just bench set=pr profile=all` twice in a row. Expected: both pass. The second run's `compare` against the first (`tcbench compare <run2> --baseline-from-run <run1>`) shows total p50 within ±5 % and identical WER/chrF++ (NFR-BH-01). If it does not, stop: record the variance in this file and propose thresholds of 3 × the variance (option d of Task 1).
- [ ] **Step 2:** Run `just bench set=full profile=all` once. Print and record its duration.
- [ ] **Step 3:** `just bench-baseline latest "first baseline: phase 1 ES↔EN, Basic + Best local"` from a clean tree. This writes `bench/baseline.json`.
- [ ] **Step 4: Commit** the baseline: `git commit -m "chore(bench): first phase-1 baseline"`
- [ ] **Step 5:** `just pr`. Expected: green, with the bench step showing ✅ against the fresh baseline.
- [ ] **Step 6: Handoff.** Give the user the report path, and publish it as a private page if they ask. Hand over the manual checks M1–M5 from requirements.md:
  - M1: record the prompt sheets, then `just bench-ingest`.
  - M2: read the report.
  - M3: correct the reference translations.
  - M4: Common Voice: get a token or decline.
  - M5: done before this task.

  Remind the user about the F8.5.4 checks M1–M6 + M2b, which are still pending.

---

## Spec coverage

| Requirement | Task |
|---|---|
| REQ-BH-01…08 | T8 (REQ-BH-04 own data: T12; REQ-BH-06: no audio committed, T8/T12; REQ-BH-07 PR < 150 MB: T8 Step 4; REQ-BH-08 MT-only: T6 + T8) |
| REQ-BH-10…13 | T2, T3 (overhead test T2; dropped reasons T2/T9) |
| REQ-BH-20…26 | T1 (tier, REQ-BH-26), T5 (real coordinator, isolation, prerequisites), T6 (pacing, idle wait, run lines) |
| REQ-BH-30…34 | T5 (profiles, Edge, overrides), T6 (engines in meta, REQ-BH-32) |
| REQ-BH-35…39 | T9 (metrics), T6 (run metadata REQ-BH-39) |
| REQ-BH-40, 41 | T13, T12 |
| REQ-BH-50…54 | T6 (raw.json history), T9 (metrics), T10 (compare, thresholds, baseline), T11 (report), T15 (retire latency.json) |
| REQ-BH-60…62 | T14, T7 |
| NFR-BH-01 | T1 (gate), T16 Step 1 |
| NFR-BH-02 | T1 (gate), T14 Step 3, T16 |
| NFR-BH-03 | T5 `userDefaultsUntouched`; fake output, nothing played |
| NFR-BH-04 | P1 (no coordinator change), T3 Step 4 unit tier |
| NFR-BH-05 | T8 licence allow-list, T11 attributions |

## Found while executing

_(Record deviations, flakes and measurements here, as in F8.5.4.)_
