# M9 — Benchmark & Eval Harness — Design

> Status: DRAFT (2026-10-17). Implements `requirements.md`. Code map from a read of `main` at f72378a.

## 1. Overview

```
            ┌──────────── Python (uv, cross-platform) ────────────┐
 HF / OpenSLR ─► bench fetch ─► cache (~/Library/Caches/TranslateCallBench)
                 bench manifest ─► bench/manifests/*.json  (committed)
                 bench ingest   ─► own recordings → manifest entries
            └──────────────────────────────────────────────────────┘
                          │ clips + manifest
            ┌──────────── Swift runner (test target, tier "bench") ─┐
            │ FileAudioSource / FileSystemAudioCapture              │
            │   → production AudioCoordinator (real VAD/STT/MT/TTS) │
            │   → TracingDecorators → TraceSink                     │
            │   → RecordingOutput (fake device, instant drain)      │
            └─────────► build/bench/runs/<run-id>/raw.json + audio/ ┘
                          │
            ┌──────────── Python ─────────────────────────────────┐
            │ bench analyze  → metrics.json (WER, cuts, chrF++, COMET, p50/p90)
            │ bench compare  → terminal table ✅/❌, exit code
            │ bench report   → report.html (self-contained)
            │ bench baseline → bench/baseline.json (committed)
            └──────────────────────────────────────────────────────┘
```

The design rests on three decisions:

1. **Swift only produces raw observations.** It records timestamps, recognised text, translations and audio paths. Every metric is computed in Python, so a future Windows runner only has to write the same `raw.json`.
2. **The production pipeline is untouched except for one new, opt-in module, `Core/Trace/`.** All seams the runner needs already exist in `AudioCoordinator.init`:
   - `audioCapture` and `systemCapture` (`AudioCoordinator.swift:143-160`);
   - the stage factories;
   - `TTSEngineSelector.outputFactory` (`TTSEngineSelector.swift:66`).
3. **Correlation is by order, not by id** (REQ-BH-10). Each direction is a FIFO chain, and the runner feeds one clip at a time and waits for idle. Order-based matching is then exact for the bench, and good enough for an in-app latency indicator later.

## 2. Production trace (`TranslateCall/Core/Trace/`)

### 2.1 Types

```swift
enum TraceDirection: String, Sendable, Codable { case outgoing, incoming }
enum TraceStage: String, Sendable, Codable {
    case speechStart, vadEnd, sttFinal, translated, ttsFirstBuffer, ttsEnd, dropped
}
struct TraceEvent: Sendable, Codable {
    let direction: TraceDirection
    let seq: Int               // per-direction utterance sequence, starts at 0 per session
    let stage: TraceStage
    let at: UInt64             // mach_continuous_time, converted to ns
    let detail: [String: String] // engine, text, reason, mergedSeqs, …
}
protocol TraceSink: Sendable { func record(_ event: TraceEvent) }
struct NoopTraceSink: TraceSink { func record(_ event: TraceEvent) {} }
```

`PipelineTracer` is an actor, one per direction:
- It keeps the counters: the next VAD segment seq, the next STT result seq, and so on. It emits the matching signpost interval, using `OSSignposter` with subsystem `com.translatecall.trace` and one interval per stage.
- It forwards each event to the sink.
- Sequence numbers advance independently per stage. An STT result is matched to the oldest VAD segment that has no result yet. When an STT engine emits nothing for a segment (empty text, or a confidence below `minimumConfidence`), that segment is closed as `dropped(reason: "stt-empty")`. The STT decorator does this when the next segment arrives, or at idle.

### 2.2 Decorators

| Stage | Decorator | What it records |
|---|---|---|
| VAD | `TracingVADService: VADService` | Re-yields `speechSegments`. `speechStart` = `segment.capturedAt`, converted to the monotonic clock once per session. `vadEnd` = the moment the segment is yielded. |
| STT | `TracingSTTService: SpeechRecognizerService` | Re-yields `transcriptionStream`. `sttFinal` with text, engine and confidence. |
| Translation | `TracingTranslationService: TranslationService` | `translated` after `translate` returns, with the text. On a throw, `dropped(reason: "translate-<error>")`. |
| TTS output | `TracingAudioOutput: AudioOutputting` | Wraps the device output. The first `schedule` after a `speak` gives `ttsFirstBuffer`, and the completed handle gives `ttsEnd`. |

- **TTS merges** (`TTSPlaybackService.takeNext()`, `TTSPlaybackService.swift:200-209`). The TTS output decorator does not know which texts were merged. `TracingSynthesisService` wraps `SynthesisService.speak` and keeps the FIFO of spoken seqs. When a first buffer arrives while more than one seq is pending, it emits one `ttsFirstBuffer` for each pending seq, with `mergedSeqs`.
- **Echo-gate drops** (speakers mode) never reach the VAD, so no trace event exists for them. That is correct: no speech was seen.
- **Hot path.** All decorators work on the stream and actor side, never on the audio render thread. `record` is called off the real-time thread, and signposts are cheap (REQ-BH-12). Overhead is measured by a unit test: 10 000 events through `PipelineTracer` with a `NoopTraceSink` must average under 50 µs per event.

### 2.3 Wiring

- The builder wraps the coordinator's factories with `PipelineTracer`'s wrappers (`tasks.md` P1); `AudioCoordinator` is unchanged.
- A later task, out of scope here, may pass a bounded ring-buffer sink for the in-app latency indicator in the UI thread. The UI thread (2026-10-17) asked for a per-direction latency, "end of speech → first audio", shown as one number such as "0.9 s".
  - In production there is no ground-truth speech end. So the `vadEnd` event carries `segmentAudioMs` and `trailingSilenceMs`, which come from the VAD configuration's `minSilence`. A sink can estimate `speechEnd ≈ vadEnd − trailingSilenceMs`.
  - The other status-panel fields (state, last line, notices, incoming lost) already come from the coordinator's published state and events. They are not part of the trace.
- The `TracingAudioOutput` wrap happens where the TTS factory builds its output, through `TTSEngineSelector.outputFactory`. The coordinator does not see outputs, so the bench wires this wrap itself (§3.3).

## 3. Swift runner (`TranslateCallTests/Bench/`)

### 3.1 Tier and invocation

- New test plan `TestPlans/Bench.xctestplan` with `TC_TEST_TIER=bench`, `executionTimeAllowance` 7200 and `-only-testing:TranslateCallTests/BenchTests`.
- `BenchTests` is `.serialized`, enabled only when `TestTier.current == .bench`, with tag `.bench`.
- Parameters arrive as environment variables. `xcodebuild` forwards them with the `TEST_RUNNER_` prefix, and `just bench` sets them:
  - `TC_BENCH_SET=pr|full`;
  - `TC_BENCH_PROFILE=basic|best|all`;
  - `TC_BENCH_EDGE=0|1`;
  - `TC_BENCH_OVERRIDE_STT` / `TC_BENCH_OVERRIDE_TTS`;
  - `TC_BENCH_CACHE`;
  - `TC_BENCH_OUT` (the run directory, created by `just`);
  - `TC_BENCH_MANIFEST`.
- One test function per run line × profile (REQ-BH-23), so a failure names the line, for example `outgoing_esES_en_basic()`.
- `just test` and `just test-integration` never select this plan (REQ-BH-26).

### 3.2 Sources

- **Mic side:** `BenchAudioSource: AudioCapture`, a new type built on `FileAudioSource`.
  - It plays a queue of clips. The runner controls it with `play(clip) async -> ClipFeed`, where `ClipFeed` holds the monotonic time of the first and the last chunk delivered, and the chunk times.
  - Between clips it streams silence, so the stream never ends inside a session. `isCapturing` stays true (needed by the supersede check at `AudioCoordinator.swift:208`).
  - It sends 16 kHz mono Float32 in 1024-sample chunks, paced by a monotonic clock with drift correction. That fits the 64-buffer cap of `SessionAudioStream`.
- **System side:** `BenchSystemAudioCapture: SystemAudioCapture`, an actor with the same playback engine, delivered through `events`, as in `Mocks/MockSystemAudioCapture.swift`. `activate(target:)` accepts any `.app(bundleID:)`; the runner passes `.app(bundleID: "bench")`.
- **Ground-truth speech end on the wall clock:** `speechEndAt` = the delivery time of the chunk that contains sample `speechEndMs·16`, plus the offset inside that chunk. `speechStartAt` is computed the same way.

### 3.3 Building the coordinator

`BenchPipelineFactory.make(profile:runLine:sink:)` builds a production `AudioCoordinator` without `AppContainer`. It builds the same objects `AppContainer.swift:34-60` builds:

- **VAD.** `VADProvider` with `settings.vadConfiguration` from a throwaway `UserDefaults(suiteName: "bench-<uuid>")`, removed after the run. Then `await vads.preload()`, because preloading is skipped in the test host (`AppContainer.swift:46`). The run fails if the provider would hand out EnergyVAD: the bench must measure Silero (requirements anti-goal).
- **STT.** An `STTEngineSelector` with the throwaway defaults. The profile sets the engine with `setPreferredEngine`, then the runner awaits availability:
  - Parakeet: `ParakeetModelManager.shared.stateStream` reaches `.ready`, within 120 s.
  - Otherwise the run fails, naming the model (REQ-BH-25).
  - `usingFallback` must be false for the run line, or the run fails. This blocks a silent fallback to Apple Speech.
- **Translation.**
  - `TranslationEngineSelector` backed by a `TranslationHostWindow` created by the test, as in `hostTranslationBridge()` (`Prerequisites.swift:48`).
  - `isTranslationPairInstalled: AppleTranslationService.isInstalled`, so a missing pack fails at `start` with the production message, converted into a test failure.
- **TTS.**
  - A `TTSEngineSelector` with the throwaway defaults.
  - Its `outputFactory` is replaced with `{ _ in TracingAudioOutput(RecordingOutput(wrapping: FakeOutput(autoComplete: true))) }`. Nothing plays on the speakers (NFR-BH-03), and the recorded buffers are written to `audio/<seq>.wav`.
  - Best local:
    - `voiceCloning.enabled = true` in the throwaway defaults.
    - `activeVoiceProfileId` is the user's active profile id, read once from the real defaults; reading is allowed, writing is not.
    - `setProfileStore` gets the real `VoiceProfileManager` store, read-only.
    - The runner waits until `voiceCloneAvailable` is true, or fails.
  - Basic: AVSpeech is preferred. Edge is disabled unless `TC_BENCH_EDGE=1`.
- **Instant drain** (`FakeOutput(autoComplete: true)`).
  - TTS playback does not use wall time, so the run takes about as long as the input audio, not input plus output (NFR-BH-02).
  - Latency up to `ttsFirstBuffer` is not affected.
  - `ttsEnd` in bench runs means "synthesis delivered", and the report labels it that way.
  - In headphones mode (the bench mode) the echo gate does not depend on playback.
- **Session.**
  - Outgoing run lines: `coordinator.start(captureTarget: nil, blackHoleDeviceID: nil)`. The outgoing TTS output goes to the fake device.
  - Incoming run lines: `start(captureTarget: .app("bench"), …)`.
  - In both cases the coordinator also activates the unused direction. That is harmless, because only silence goes in.
- **Isolation.** The real defaults are snapshotted before the run and compared after it; any difference fails the test (REQ-BH-24). Every selector receives the throwaway suite.

### 3.4 Clip loop

```
start session → wait for warm-up (translation warm-up + 2 s silence)
for clip in runLine.clips:
    feed = await source.play(clip)                 // real time
    await waitIdle(seqsOpenedSince: feed.start, timeout: 15 s)  // silence keeps flowing
    await silence(0.5 s)
stop session; flush sink; write raw.json
```

- `waitIdle` returns when every trace seq opened since `feed.start` has reached `ttsFirstBuffer`+`ttsEnd` or `dropped`, and no `vadEnd` has been seen for (pause + 0.5 s).
- Seq-to-clip assignment lives in `tcbench analyze` (P2).
- A clip that produced no seq is recorded as `missed`.

### 3.5 `raw.json` (schema v1)

```jsonc
{
  "schema": 1, "runId": "2026-10-20T10-12-03Z-ab12cd3", "set": "pr", "profile": "basic",
  "runLine": "outgoing es-ES>en", "informative": false, "override": null,
  "meta": {
    "commit": "...", "dirty": false, "machine": "Mac16,10", "macOS": "26.1 (25B…)",
    "xcode": "27.0", "manifestSha256": "...",
    "engines": {"vad": "silero", "stt": "appleSpeech", "translation": "apple", "tts": "avSpeech",
                "models": {"parakeet": "...", "qwen": "..."}},
    "settings": {"pauseSeconds": 0.6, "vadChunkSamples": 4096, "listeningMode": "headphones"}
  },
  "clips": [{ "id": "fleurs-es419-1234", "feedStartNs": 0, "speechStartNs": 0, "speechEndNs": 0,
             "seqs": [3, 4], "missed": false }],
  "utterances": [{ "seq": 3, "cold": false,
                   "events": {"speechStart": 0, "vadEnd": 0, "sttFinal": 0, "translated": 0,
                              "ttsFirstBuffer": 0, "ttsEnd": 0},
                   "sttText": "...", "translation": "...", "mergedSeqs": [], "dropped": null,
                   "audio": "audio/3.wav" }],
  "mtOnly": [{ "id": "ntrex-en-0042", "src": "...", "hyp": "...", "ms": 231 }]
}
```

The MT-only text set (REQ-BH-08) runs inside the same session, before the clip loop. Each sentence goes straight to the run line's `TranslationService` (bypassing audio), and the per-sentence time is kept for information only.

### 3.6 Run duration (NFR-BH-02)

| Run lines × profiles (PR) | Clips | Seconds per clip (≤ 6 s clip + 0.6 s pause + ~1 s idle + 0.5 s gap) | Total |
|---|---|---|---|
| 4 lines × Basic + 3 lines × Best (incoming Best = Basic engines, so skipped) | 8 each → 56 | ~8 | ~7.5 min |
| MT-only 2 × 100 sentences in PR, 2 × 200 in full (P5) | — | ~0.3 | ~1 min (PR) |
| Session warm-ups, 7 × ~3 s | — | — | ~0.4 min |

The total is about 10 min, which is tight. **Measure-first gate (task 1 of the plan):** measure the real PR duration and the run-to-run variance (NFR-BH-01) before building the analysis side. Planning options were (a) PR runs only Basic, (b) 6 clips per line, (c) MT-only 100 sentences. Resolved: (c) applied in planning (P5) and (a) chosen by the user after T14 (see Decision below).

**Measured (2026-10-17, T14):** a Basic line takes about 2.25 min (137, 131 and 136 s for 3 lines); 3 lines took 7m18s end to end, including the build and analysis. The estimate in `tcbench.estimate` is calibrated on this (clip seconds x 2.0 + 15 s per line + 0.3 s per MT sentence + 60 s fixed). The full 4-line Basic run is therefore about 9 min, and adding Best would pass the 10 min limit.

**Decision (user, 2026-10-17):** option (a). `just pr` runs the PR set for the Basic profile only (`just bench pr basic`, about 9 min). Best local is measured with `just bench` (pr or full) and before each latency change. `bench.sh` warns when a PR estimate exceeds 10 min.

## 4. Python tooling (`tools/bench/`)

- `pyproject.toml` + `uv.lock`. Python 3.12. Package `tcbench`, CLI `tcbench <cmd>`.
- Dependencies, all pinned:
  - `huggingface_hub` (snapshot parquet / audio download);
  - `soundfile`, `soxr` (resample);
  - `numpy`;
  - `silero-vad` (MIT) for ground truth;
  - `jiwer` is not used. WER is a port of the Swift normalisation and has its own golden tests against `WordErrorRateTests` cases.
  - `sacrebleu` (chrF++);
  - `jinja2` + inline Vega-Lite JSON for the report, with the Vega bundle embedded, so the page is self-contained and works offline;
  - optional extra `comet` → `unbabel-comet` (torch). It is installed only for full runs (`uv run --extra comet`).
- Commands:
  - `tcbench fetch [--set pr|full]`
  - `tcbench manifest`
  - `tcbench ingest <dir>`
  - `tcbench analyze <run-dir>`
  - `tcbench compare [run] [--baseline bench/baseline.json]`
  - `tcbench report <run-dir>`
  - `tcbench baseline <run-dir> --reason`
- Tests: `pytest` under `tools/bench/tests`, run by `just check` (Linux CI as well, REQ-BH-62). They cover:
  - normalisation and WER;
  - the manifest's determinism;
  - percentile maths;
  - threshold verdicts;
  - seq-to-clip assignment;
  - the cut and merge rates on synthetic `raw.json` fixtures.

### 4.1 Sources and selection (`tcbench manifest`)

| Source | HF id / origin | Revision | Variant | Phase 1 selection |
|---|---|---|---|---|
| FLEURS | `google/fleurs` (`es_419`, `en_us`, test) | pinned commit | es-419, en | Sentence ids present in both; clips 2–12 s; seed 1729; full 300, PR 8 per line (≤ 6 s) |
| VoxPopuli | `facebook/voxpopuli` (`es`, test) | pinned | es-ES | Transcribed segments 2–12 s; transcript starts with a capital and ends with sentence-final punctuation; full up to 300, PR up to 8 (see the lead/tail rule) |
| Smart Turn v3 test | `pipecat-ai/smart-turn-data-v3-test` | pinned | es-ES*, en | **Deferred to project 2.** `spa`/`eng` rows, balanced complete/incomplete; full 200 per language; not in PR |
| NTREX-128 | GitHub `MicrosoftTranslator/NTREX` | pinned commit | text | 200 sentences per direction, seed 1729 |
| Own recordings | local folder | — | es-ES, en (non-native) | Everything ingested; PR 8 per variant once present |

\* Smart Turn does not tag Spanish variants. Its Spanish rows go in as `es-xx` (unknown) and are reported apart, never mixed into `es-ES` (D-5).

- **Ground truth** (REQ-BH-03). Silero (python, 512-sample / 32 ms windows, threshold 0.35) finds the speech span; an energy step then refines each edge locally. Frame energy is RMS in dB at 10 ms hops. The noise floor is the 20th percentile of the frame dB outside Silero's span (whole clip if fewer than 20 such frames); the threshold is floor + 10 dB, never below peak − 40 dB. Each edge is searched in both directions but only within ±300 ms of Silero's edge, and needs at least 3 consecutive frames (30 ms) above the threshold, so a click cannot set it. (A rule "within 25 dB of peak, trimming inward" was tried and rejected: on clean recordings it sits far above the noise floor and cuts soft codas, so `speechEnd` came out early.) A clip is dropped and logged, with its reason, when: it is silent; SNR (peak − floor) is below 20 dB; no run is found at an edge; or the refined end is more than 200 ms from Silero's end (the 32 ms windows and hangover give a known positive Silero offset, measured at about 70 ms median and 160–190 ms p90 on FLEURS). Every source also requires at least 200 ms of file before the span and 300 ms after it. If a variant cannot reach its quota under these filters, the smaller N is accepted and recorded; the filters are not relaxed. The production VAD uses 256 ms chunks and threshold 0.85, so the configurations differ but the model is the same. That bias is recorded in the report footer.
- **Common Voice** (gated, optional) is a recorded phase-1 deferral: with `TC_BENCH_CV_TOKEN` set, selection is still not implemented.
- **Level normalisation.** Every clip is levelled at manifest time to an active-speech RMS of −26 dBFS: the RMS over the speech span (found by a first Silero pass on the source) gives one gain for the whole clip, reduced if needed so the peak stays at or below −1 dBFS. The result is quantised to int16, exactly as written to the cache, and the ground truth is then computed on those int16 samples; the sha256 is of that exact WAV. The gain is recorded per clip as `gainDb` (Swift ignores it; `fetch` re-applies it, so the cache reproduces the sha256). Reason: the bench measures the pipeline, not robustness to input level, and en and es clips must be comparable (FLEURS en was about 33 dB quieter than es-419 before this step).
- **Phase-1 counts** (pinned revisions of 2026-10-17): FLEURS en 277 (PR 8; all 505 candidates tried, shortfall accepted), FLEURS es-419 300 (PR 8), VoxPopuli es-ES 1 full and no PR clip, because almost every segment lacks the required lead/tail silence (see the Task 8 report).
- **Licence allow-list** lives in `bench/licences.json`. `fetch` refuses any source missing from it.

### 4.2 Metrics (`tcbench analyze`)

- **Latency.**
  - Per utterance: `vadMs = vadEnd − speechEnd(clip)`, `sttMs`, `translateMs`, `ttsFirstAudioMs`, `totalMs = ttsFirstBuffer − speechEnd(clip)`.
  - For a clip with several seqs, latency counts only on the **last** seq; earlier seqs are cuts.
  - Aggregates: p50, p90 and mean (numpy `percentile`, linear) per profile × run line, plus cold reported apart.
- **WER.** Corpus WER per profile × run line, built from the concatenated `sttText` of a clip's seqs against the reference.
- **Cut rate.** The share of clips with more than one seq, plus the share of Smart Turn `incomplete` clips that produced a closed turn before `speechEnd`. **Merge rate** is reported apart.
- **chrF++** (`sacrebleu.CHRF(word_order=2)`) for:
  - the pipeline (the concatenated translation against the reference translation, FLEURS and own clips);
  - MT-only (NTREX / FLEURS text).
- **COMET** (`Unbabel/wmt22-comet-da`, pinned revision), on the same pairs, full set only.
- **Missed clips and dropped utterances** are counted and listed.

### 4.3 Compare, thresholds, baseline

- `bench/thresholds.json` holds REQ-BH-52 values. `bench/baseline.json` holds aggregates keyed by `profile/runLine`, plus `reason`, `date`, `commit` and `manifestSha256`.
- `compare` refuses a run whose `manifestSha256` differs from the baseline's. The message says to re-baseline after a manifest change.
- Output: a fixed-width table with ANSI colours when the output is a TTY.
- Exit code 1 on any ❌ in a gated metric. Latency rows are gated only when `set == full`.

### 4.4 Report (`tcbench report`)

`report.html` is written into the run directory. The audio of the worst utterances is embedded as base64 Opus (a size cap of 8 MB per report). It contains:
- the run header and metadata;
- a stage-breakdown stacked bar chart per profile × run line;
- a latency histogram;
- a baseline comparison table;
- a trend chart of the last N runs from `build/bench/runs/*/metrics.json`;
- the 10 worst by total and the 10 worst by WER, with `<audio>` for the source and the TTS output, and the texts;
- attributions.

It is local by default; Claude may publish it as a private page when the user asks.

## 5. Own recordings

- Prompt sheets: `bench/prompts/es-ES.md` and `bench/prompts/en.md`.
  - Each row: id, purpose tag, the text with `‖` at the intended pause points, and the reference translation.
  - The sheet also gives reading instructions: a quiet room, the Mac's built-in mic or a headset, about 1 s of silence before and after, and a file name equal to the id.
- `tcbench ingest <dir>`: accepts wav/m4a/aiff, normalises the audio, computes the ground truth (§4.1) and detects internal pauses longer than 250 ms.
  - It matches the detected pauses to the `‖` marks, with a tolerance of one mark.
  - It flags clipping (more than 0.1 % of samples at full scale), silence-only files, and a speech-length ratio outside 0.5–2.0 of the estimate (the number of words ÷ 2.5 w/s).
  - It writes `own-*` manifest entries with `nativeSpeaker` set from a flag.

## 6. `just` and scripts

| Recipe | Does |
|---|---|
| `bench-fetch set="pr"` | `uv run tcbench fetch --set {{set}}` |
| `bench-manifest` | `uv run tcbench manifest` (maintainers; rewrites the committed manifest) |
| `bench-ingest dir` | `uv run tcbench ingest {{dir}}` |
| `bench set="pr" profile="all" edge="0"` | `tools/scripts/bench.sh`: fetch the set if missing → build for testing → `xcodebuild test-without-building -testPlan Bench` with the env → `tcbench analyze` → `tcbench compare` (exit code passes through) → print the report path |
| `bench-compare run="latest"` | `uv run tcbench compare` |
| `bench-report run="latest"` | `uv run tcbench report` |
| `bench-baseline run reason` | `uv run tcbench baseline` (refuses a dirty tree, an informative run or an overridden run) |

- `pr.sh` gains a step after `test-integration`: `just bench set=pr profile=all`. The step fails when `compare` exits non-zero.
- `setup.sh` installs `uv` (version pinned in `tools/versions.env`) and runs `uv sync`.

## 7. Retiring `latency.json` (REQ-BH-50)

- Delete `TranslateCallTests/Support/LatencyReport.swift` and its `record` calls in:
  - `OutgoingPipelineFixtureTests`;
  - `STTFixtureTests`;
  - `TranslationFixtureTests`;
  - `TranslationBridgeIntegrationTests`;
  - `SileroSegmentationIntegrationTests`.

  The tests keep their assertions (the 400 / 600 ms ceilings) and print the figures to the test log.
- `TranslationLatencyTests` stays as a diagnostic, without the report.
- Update F8.5.0 `design.md` and `requirements.md` REQ-W-24 with a pointer: "superseded by M9 benchmark harness".
- Mark backlog A14 as fixed by this feature.

## 8. Testing

- **Unit (Swift).**
  - `PipelineTracer` order matching: STT drops, translation errors, TTS merges.
  - Each decorator passes values through unchanged.
  - Overhead (§2.2).
  - `BenchAudioSource` pacing and chunk timestamps under `TestClock`.
  - Seq-to-clip assignment.
- **Unit (Python).** As listed in §4.
- **Integration (existing tier).** One test runs `BenchPipelineFactory` with the Basic profile on two existing `say` fixtures. It checks that a complete trace comes back for each and that the user defaults are unchanged. This keeps the bench path alive in `just pr` even if the bench tier is skipped by mistake.
- **Bench tier.** The bench itself.
- **Manual.** M1–M5 in requirements.md.

## 9. Files

| New | Changed |
|---|---|
| `TranslateCall/Core/Trace/{TraceEvent,TraceSink,PipelineTracer,Tracing*}.swift` | none in `AudioCoordinator` (P1: builders wrap the factories with `PipelineTracer`) |
| `TranslateCallTests/Bench/{BenchTests,BenchPipelineFactory,BenchAudioSource,BenchSystemAudioCapture,BenchRunWriter}.swift` | `justfile`, `tools/scripts/pr.sh`, `tools/scripts/setup.sh`, `tools/versions.env` |
| `TranslateCallTests/TestPlans/Bench.xctestplan` | Integration tests listed in §7, `LatencyReport.swift` (deleted) |
| `tools/bench/` (pyproject, uv.lock, `tcbench/`, `tests/`) | `.gitignore` (`tools/bench/.venv`) |
| `tools/scripts/bench.sh` | F8.5.0 spec pointer, `backlog.md` (A14) |
| `bench/{manifests/,prompts/,baseline.json,thresholds.json,licences.json}` | |

## 10. Risks

- **Silero `capturedAt` is a `Date`.** It is converted to monotonic time with one offset per session. If NTP slews during a run, `speechStart` drifts by milliseconds at most; that is accepted. Every other stamp is monotonic.
- **Apple Speech / Translation behaviour across macOS updates** moves the baseline. The run metadata records the macOS build, and `compare` warns when it differs from the baseline's.
- **Qwen3-TTS memory on long full runs.** The runner restarts the session between run lines.
- **Order correlation breaks if a stage reorders.** Today none does. A unit test pins the FIFO assumption for each decorator.
