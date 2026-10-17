# M9 — Benchmark & Eval Harness — Requirements

> Status: APPROVED (2026-10-17). Source: `design-brief.md` (approved by the user 2026-10-17).
> Thread: M9 latency, project 1 of 2. Project 2 (latency cuts) depends on this harness.
> Backlog links: `specs/m8.5-stabilization/backlog.md` T4, T7 (latency), A14 (no end-to-end harness); F8.5.0 REQ-W-24 (`latency.json`) is superseded here.

## Overview

TranslateCall has latency numbers but no trustworthy benchmark. The existing figures come from:
- six synthetic `say` clips;
- stages wired by hand in the tests;
- EnergyVAD instead of the production Silero VAD;
- a "speech end" taken as the end of the WAV file;
- one value per row, overwritten on every run.

There is no measure of translation quality and no baseline to compare against.

This feature builds a reproducible benchmark and eval harness:
- Recorded human speech from public datasets, plus the user's own recordings, is fed from files through the production pipeline in real time.
- Each utterance is traced stage by stage.
- Latency (p50/p90) and quality (WER, cuts, chrF++, COMET) are computed and compared with a committed baseline.
- Results come as a terminal verdict table and an HTML report.

Phase 1 covers ES→EN and EN→ES, with Spain Spanish (`es-ES`) and Latin American Spanish (`es-419`) kept apart.

## Decisions (brainstorming 2026-10-17)

| ID | Decision |
|----|----------|
| D-1 | Measure before improving. No latency change (project 2) is accepted without harness numbers. Real-call tests come after. |
| D-2 | Public datasets first: FLEURS (CC BY 4.0), VoxPopuli (CC0), Smart Turn v3 test (CC BY 4.0), NTREX (CC BY-SA 4.0). Common Voice (CC0) is optional, because access is gated. Europarl-ST may be used only once its licence is confirmed. Non-commercial or no-derivatives data (CoVoST 2, MuST-C, mTEDx) and metric models (CometKiwi, XCOMET) are excluded. |
| D-3 | The user records gap-filling clips from prompt sheets that Claude prepares: `es-ES` by the user; `en` by the user, labelled non-native. |
| D-4 | Phase 1 pairs are ES→EN and EN→ES only. Adding a language or pair costs data and manifest entries, not code. |
| D-5 | `es-ES` and `es-419` are separate variants in data and results. `es-ES` is primary. An app-level variant selector is backlog. |
| D-6 | Results come in three layers: per-run JSON history, a terminal comparison with ✅/❌, and an HTML report with the worst utterances and their audio. |
| D-7 | Two pinned, fully offline engine profiles, both gated: **Basic** (fresh install) and **Best local**. Edge TTS is on-demand and informative only. |
| D-8 | The headline metric is total latency, from the real end of speech to the first TTS buffer scheduled. |
| D-9 | Production code may change, minimally and with review, to add the per-utterance trace and the file-driven audio seams. |
| D-10 | The baseline is a small results-only JSON committed in the repo. Re-baselining is an explicit recipe with a recorded reason. |
| D-11 | Data, schema and reporting tooling are platform-neutral (Python with `uv`). Only the runner that drives the app is macOS-specific, which keeps a future Windows build comparable. |

## Functional Requirements

### FR-BH-1 — Datasets and manifests

**REQ-BH-01**: A versioned **dataset manifest** (JSON, in the repo) SHALL list every clip used by the harness. Each entry SHALL have these fields:
- `id`
- `source` (dataset name, revision or commit, original clip id)
- `lang`
- `variant` (for example `es-ES`, `es-419`, `en`)
- `speaker` (an anonymous id) and `nativeSpeaker` (bool)
- reference transcript
- reference translations keyed by target language, where available
- `speechStartMs` and `speechEndMs` (ground truth)
- `tags` (for example `fleurs`, `voxpopuli`, `own`, `long`, `hesitation`, `multi-sentence`, `incomplete-turn`)
- `tiers` (`pr`, `full`)
- `sha256` of the normalised audio
- licence

**REQ-BH-02**: A fetch command (`just bench-fetch`) SHALL download the sources named in the manifest into a local cache outside git. The cache path defaults to `~/Library/Caches/TranslateCallBench/` and can be overridden by `TC_BENCH_CACHE`. The command SHALL:
- normalise the audio to 16 kHz mono 16-bit WAV;
- verify each `sha256`;
- be idempotent;
- fail with a clear message naming the clip or source on any mismatch or download error.

**REQ-BH-03**: A manifest-building command SHALL select clips from each source with a fixed seed and pinned dataset revisions, and SHALL compute the ground-truth `speechStartMs`/`speechEndMs`. These values SHALL NOT be derived from the file length. Re-running the command with the same inputs SHALL produce a byte-identical manifest.

**REQ-BH-04**: Phase 1 data SHALL include:
- FLEURS test `es_419` and `en_us`, restricted to sentence ids present in both, with reference transcripts and the parallel sentences as reference translations;
- VoxPopuli `es` test as `es-ES`;
- the Smart Turn v3 test rows for Spanish and English, with their end-of-turn labels;
- NTREX `es`/`en` for text-only MT evaluation;
- the user's own recordings once they exist (REQ-BH-40).

**REQ-BH-05**: The fetch command SHALL refuse a source whose licence is not in the allow-list (D-2). Gated sources (Common Voice) SHALL be skipped with an explicit message when no access token is configured. The gated source missing SHALL NOT be an error unless the selected set requires it.

**REQ-BH-06**: No dataset audio, derived audio or cache content SHALL be committed. Manifests, prompt sheets, the baseline JSON and the user's reference texts SHALL be committed. The user's own audio stays in the cache unless the user decides otherwise.

**REQ-BH-07**: Two sets SHALL exist:
- **PR set:** 8–10 clips per run line (REQ-BH-23); total download under 150 MB. It is sized to fit NFR-BH-02.
- **Full set:** every manifest clip.

  Membership is the `tiers` field.

**REQ-BH-08**: An MT-only text set SHALL exist: 100 sentences per direction in the PR tier and 200 in the full tier, translated directly through Apple Translation with no audio. It runs in both tiers and gives a stable chrF++ signal in a minute or two.
### FR-BH-2 — Production trace

**REQ-BH-10**: The production pipeline SHALL carry a **per-utterance trace** through each direction. It SHALL be implemented as tracing decorators around the injected VAD, STT, translation and TTS-output stages. The trace is correlated by order within a direction, since stages are FIFO per direction. It is not done by threading an id through the stage protocols. When TTS merges queued sentences, the trace SHALL record that the utterances were merged. It SHALL record monotonic timestamps for:
- speech segment start (first VAD speech frame);
- VAD end-of-turn decision;
- STT final result;
- translation result;
- first TTS audio buffer scheduled on the output;
- TTS playback end.

  It SHALL also carry the direction, the engines used and the settings that affect timing (pause length, VAD frame size).

**REQ-BH-11**: The trace SHALL be emitted as `os_signpost` intervals (one subsystem, one category per stage) for Instruments. It SHALL also be delivered to an injectable trace sink. The default production sink SHALL be a no-op or a bounded in-memory buffer, with no file I/O and no unbounded growth.

**REQ-BH-12**: Tracing SHALL NOT add measurable latency. The overhead per utterance SHALL be under 1 ms, measured. Tracing SHALL NOT allocate on the real-time audio thread.

**REQ-BH-13**: A skipped or failed utterance SHALL still produce a trace with the stage at which it ended and the reason, for example: dropped by the echo gate, empty STT, translation failed, or TTS skipped.

### FR-BH-3 — File-driven runner

**REQ-BH-20**: The runner SHALL drive the production `AudioCoordinator`, with production VAD, STT, translation and TTS objects. Only these SHALL be replaced:
- the microphone source, by a file source;
- the system/call-app source, by a file source;
- the TTS output devices, by recording outputs that timestamp scheduled buffers and keep the audio.

  Wiring pipeline stages by hand SHALL NOT count as a harness run.

**REQ-BH-21**: File sources SHALL deliver audio paced in real time at the production capture format and chunking, and SHALL timestamp the moment each chunk is delivered. After each clip, the runner SHALL keep feeding silence until the direction is idle: every utterance of the clip has reached a final trace state, or 15 s have passed. It SHALL then add a fixed 0.5 s gap before the next clip, so one clip never overlaps the next one's turn.

**REQ-BH-22**: The runner SHALL map each trace to its manifest clip and compute, per utterance:
- `vadMs` = VAD end-of-turn − ground-truth speech end;
- `sttMs`, `translateMs` and `ttsFirstAudioMs` as stage-to-stage deltas;
- `totalMs` = first TTS buffer − ground-truth speech end.

  The first utterance after Start SHALL be flagged `cold`.

**REQ-BH-23**: Each direction SHALL be measured on its own; overlapping two-way speech is out of scope. Phase 1 run lines:
- **outgoing** `es-ES`→en and `es-419`→en (mic-side files);
- **outgoing** en→es;
- **incoming** en→es (system-side files; the realistic role of the remote English speaker).

  Each run line is run once per profile.

**REQ-BH-24**: The runner SHALL select the engine profile explicitly (REQ-BH-30) and SHALL NOT read or write the user's saved engine preferences. Saved preferences SHALL be the same before and after a run.

**REQ-BH-25**: Missing prerequisites SHALL fail the run with a message naming what is missing. They include:
- a language pack not installed;
- a profile model not downloaded;
- the dataset cache missing after a fetch attempt;
- no voice-clone profile for Best local.

  They SHALL NOT skip silently (consistent with F8.5.0).

**REQ-BH-26**: The runner SHALL run inside the existing test target, under a new tier (`TC_TEST_TIER=bench`). `just test` and `just test-integration` SHALL never run it implicitly.

### FR-BH-4 — Engine profiles

**REQ-BH-30**: The **Basic** profile SHALL use:
- Apple Speech STT, with the `es-ES`, `es-MX`/`es-419` or `en-US` locale matching the clip variant;
- Apple Translation;
- the AVSpeech system voices for the target language.

**REQ-BH-31**: The **Best local** profile SHALL follow the app's own engine priorities with every local model present:
- STT: Parakeet for English outgoing; Apple Speech for Spanish and for the incoming direction, since Parakeet is English- and outgoing-only in the app today and Whisper `base` is weak (backlog T2);
- Apple Translation;
- TTS outgoing: the user's voice clone (Qwen3-TTS), which outranks Kokoro in the app;
- TTS incoming: AVSpeech, the only local incoming engine.

  The runner SHALL name the voice-clone profile it uses. Kokoro is measured through the engine override (REQ-BH-34), not as part of a profile.

**REQ-BH-32**: Every run record SHALL list the resolved engine per stage and direction, and the model identifiers and versions where the engine exposes them.

**REQ-BH-33**: An on-demand **Edge** option SHALL measure Edge TTS in place of the profile's TTS. Its results SHALL be marked `informative` and SHALL never be gated or used as a baseline.

**REQ-BH-34**: An ad-hoc engine override SHALL let a run force any supported STT or TTS engine. Overridden runs SHALL be marked and SHALL NOT be accepted as a baseline.

### FR-BH-5 — Metrics

**REQ-BH-35**: Latency SHALL be reported as p50, p90, mean and count, per profile, pair, variant and stage, with cold utterances reported apart.

**REQ-BH-36**: WER SHALL use the existing normalisation (case, diacritics and punctuation ignored), aggregated as corpus WER (total errors / total reference words) per profile, pair and variant.

**REQ-BH-37**: The **cut rate** SHALL be:
- the share of clips whose speech produced more than one STT utterance (premature split);
- plus the share of Smart Turn `incomplete` clips on which the VAD closed the turn.

  The **merge rate** SHALL be the share of utterances whose audio spans two clips. Both SHALL be reported separately.

**REQ-BH-38**: Translation quality SHALL be reported as chrF++ (sacrebleu, pinned version) on every run. COMET SHALL be reported on full runs, with `Unbabel/wmt22-comet-da` at a pinned revision. Both SHALL be computed:
- on the pipeline output (STT → MT) against the reference translation, where the clip has one;
- on MT alone, from the reference transcript or NTREX text, so MT quality is separated from STT errors.

**REQ-BH-39**: Each run record SHALL include:
- commit and dirty flag;
- date;
- machine model and macOS build;
- Xcode version;
- profile and resolved engines;
- the settings that affect timing;
- manifest hash and set (pr/full);
- harness schema version.

### FR-BH-6 — Own recordings

**REQ-BH-40**: Claude SHALL prepare prompt sheets: about 40 prompts for `es-ES` and about 40 for `en`. Each prompt SHALL carry a reference translation (written by Claude, checked by the user) and a purpose tag. Purposes include:
- long sentences;
- mid-sentence hesitation (marked pause points of about 0.3–1.5 s);
- turns that end vs. turns that pause and continue;
- multi-sentence turns;
- short replies.

**REQ-BH-41**: An ingest command SHALL turn a folder of the user's recordings (any common format) into manifest entries. It SHALL:
- match files to prompts by name;
- normalise the audio and compute the ground-truth speech end;
- for prompts with marked pauses, record the expected pause positions, derived from the audio and checked against the prompt marks;
- report clips that look wrong: clipped audio, silence only, or speech far longer or shorter than expected.

### FR-BH-7 — Results, comparison and report

**REQ-BH-50**: Each run SHALL write a versioned JSON run record to a local history directory (`build/bench/runs/<timestamp>-<commit>.json`, never overwritten). It SHALL hold per-utterance rows (trace, metrics, recognised text, translation, paths to the recorded TTS audio in the run's local output directory) and the aggregates. `build/reports/latency.json` (REQ-W-24) SHALL be retired. Its existing writers SHALL be migrated or removed, so that no two latency formats remain.

**REQ-BH-51**: A compare command (`just bench-compare [run] [baseline]`) SHALL print a terminal table per profile, pair and variant. The table SHALL show each headline metric (total p50/p90, WER, cut rate, chrF++, COMET when present) with the baseline value, the delta and a ✅/❌ verdict against the thresholds. It SHALL exit non-zero when any gated verdict is ❌.

**REQ-BH-52**: Starting thresholds, held in one committed config file:
- total latency p50 regression > 10 % → ❌;
- total latency p90 regression > 15 % → ❌;
- WER up more than 2.0 points → ❌;
- chrF++ down more than 2.0 points → ❌;
- cut rate above 5 % absolute → ❌, or more than 2 points above the baseline, whichever is higher.

  Latency verdicts SHALL apply to full runs only. PR runs SHALL gate quality only.

**REQ-BH-53**: An HTML report command SHALL produce one self-contained HTML file per run, with no network access needed to view it. It SHALL contain:
- stage-breakdown charts per profile and direction;
- the latency distribution;
- a comparison with the baseline and the last N runs;
- the 10 worst utterances by total latency, and the 10 worst by WER, each with playable source audio and TTS output, reference text, recognised text, translation and reference translation.

**REQ-BH-54**: A re-baseline command (`just bench-baseline <run> --reason "..."`) SHALL copy the aggregates of a full, non-overridden, non-informative run into the committed baseline file, together with the reason, date and commit. It SHALL refuse runs from a dirty tree.

### FR-BH-8 — `just` integration

**REQ-BH-60**: New recipes:
- `bench-fetch`;
- `bench-manifest`;
- `bench-ingest <dir>`;
- `bench [--set pr|full] [--profile basic|best|all] [--edge]`;
- `bench-compare`;
- `bench-report`;
- `bench-baseline`.

**REQ-BH-61**: `just pr` SHALL run the PR set for the Basic profile, after the integration tier, and fail on a quality ❌. Best local runs on demand via `just bench` and before each latency change (user decision 2026-10-17). The PR bench runs only on the Mac mini (F8.5.0 D-4); it SHALL fetch the PR set on first use.

**REQ-BH-62**: Python tooling SHALL be run with `uv`, with versions locked (`pyproject.toml` + `uv.lock`). It SHALL have its own unit tests, run by `just check` or `just test`. It SHALL run on macOS and Linux.

## Non-Functional Requirements

**NFR-BH-01**: **Reproducibility.** Two consecutive full runs of the same commit on the Mac mini SHALL be within ±5 % on total latency p50 and give identical WER, cut rate and chrF++, since the engines are deterministic. If the engines prove non-deterministic, the variance SHALL be measured and the thresholds adjusted, as recorded in design.md.

**NFR-BH-02**: **Duration.** The PR bench SHALL add at most 10 minutes to `just pr`, including the MT-only text set. The full set's duration SHALL be printed before the run starts.

**NFR-BH-03**: **Isolation.** A bench run SHALL NOT change user defaults, voice profiles, downloaded models or audio device settings. It SHALL NOT play audio on the speakers.

**NFR-BH-04**: **No production regression.** With the trace's default sink, app behaviour and existing tests SHALL be unchanged. `just pr` SHALL stay green.

**NFR-BH-05**: **Licences.** Every source and metric model SHALL be in the allow-list with its licence recorded. The report SHALL carry the attributions required by CC BY sources.

## Out of scope

- Latency improvements (project 2).
- DE, UK and other languages: the data and baselines are not built now; the harness supports them through manifests.
- The app's `es-ES`/`es-419` selector (backlog).
- Codec-degraded audio (Zoom/Teams), BlackHole loopback, and overlapping two-way speech.
- Measuring TTS quality (later: back-transcription for intelligibility).
- A recording UI.

## Manual checks (user)

- **M1** Record the `es-ES` and `en` prompt sheets and run `just bench-ingest` on them: no clip is reported wrong, or the reported ones are re-recorded.
- **M2** Read the first baseline report (HTML): the worst utterances look plausible, and the audio plays.
- **M3** Read the reference translations for the own prompts and correct them where needed.
- **M4** Accept the Common Voice terms and set the token, or decide to stay without Common Voice.
- **M5** Make sure a voice-clone profile exists and is active, and that Parakeet is downloaded, before the first Best-local run.
