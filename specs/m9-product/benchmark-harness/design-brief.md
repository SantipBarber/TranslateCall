# M9 — Benchmark & Eval Harness — Design Brief

> Status: DRAFT (2026-10-17), from the brainstorm with the user. Input for `requirements.md` + `design.md` (SDD).
> Thread: M9 latency. The UI redesign is a separate thread (`specs/m9-product/ui-redesign/`).

## Intent

Before any latency work and before any real-call test, TranslateCall needs a professional, reproducible way to measure **how fast** and **how well** it translates. Every later latency change must prove with numbers that it cuts latency without hurting quality.

The user's words (2026-10-17): "quiero conseguir la mejora antes de hacer pruebas de fuego. Necesitamos benchmarks, evals, testing y todo en modo pro". The product goal behind it: "conseguir la comunicación entre hablantes distintos con la mejor experiencia posible".

This is project 1 of 2 in the latency thread:
1. **Benchmark & eval harness + ES↔EN baseline.** This document.
2. **Latency cuts** from `reports/Reducir latencia traducción de voz.md`: speculation, 32 ms VAD frames, Smart Turn v3, streaming partials and the rest. Each cut is accepted only with harness numbers. Brainstormed separately.

## What the user decided

- **The harness itself.** Recorded human speech runs through the full pipeline offline, with no mic and no call, exactly as if someone were speaking. It measures:
  - latency per stage: real speech end → VAD end of turn → STT final → translation → first TTS audio, as p50/p90;
  - quality: WER, mid-sentence cuts, translation quality.

  It runs on the Mac mini and compares each run against a baseline.
- **Datasets.** Public datasets come first. Datasets with non-commercial or no-derivatives licences are excluded: CoVoST 2, MuST-C and mTEDx.
- **Own recordings.** The user records clips that Claude prepares (scripts to read aloud) to fill the gaps public data leaves.
- **Phase 1 scope: ES→EN and EN→ES only.** German and other languages come later, once someone is found to record them. The strategy is "ir escalando", so adding a language or a pair must cost data and manifest entries, not code.
- **Spanish variants are kept apart.** Spain Spanish (`es-ES`) and Latin American Spanish (`es-419`) never mix in one "Spanish" dataset or result.
  - `es-ES` is the primary set.
  - `es-419` is a secondary set, kept because it is cheap (FLEURS).
  - A Spain / Latin America selector in the app is wanted **later**, not in this project (backlog).
- **Results in three layers:**
  - raw JSON per run, kept as history;
  - a terminal comparison table against the baseline with ✅/❌ verdicts;
  - an HTML report per run with charts, run-over-run comparison and the worst sentences with playable audio.
- **Colab is not the runner.** Apple Translation, Apple Speech and the ANE models exist only on macOS. Notebooks may read the JSON later.
- **Possible future Windows version.** No commitment, but it shapes how data and reports are built (see constraints).

## Goals

- One command produces a baseline for ES→EN and EN→ES with today's code: per-stage p50/p90 latency, WER, cut rate and translation quality, separately for `es-ES` and `es-419`.
- One command compares any branch against the baseline and says in seconds whether a change is worth keeping.
- `just pr` fails when quality regresses beyond agreed thresholds.
- Results can be traced and reproduced: exact clips, dataset revisions, commit, machine, engines used, settings.
- Adding a language or pair needs only data and manifest entries.

## Non-goals

- Any latency improvement (project 2).
- German, Ukrainian and other pairs. The harness must support them, but no data or baseline for them is built now.
- The Spain / Latin America selector in the app.
- Audio degraded by the Zoom/Teams codec, or BlackHole loopback runs. Later; noted as a gap.
- A simulated remote participant or container (F8.5.0 D-6 still applies).
- Training or fine-tuning on any dataset.

## Anti-goals (a failure even if it works)

- Latency figures that flatter the app, for example measuring "speech end" at the end of the WAV file including trailing silence. Today's `firstTranscript()` helper has exactly this bias and also uses EnergyVAD instead of the production Silero VAD.
- A harness that bypasses the production pipeline by wiring stages by hand. It must drive the real `AudioCoordinator` path, with the engines and settings a user would get.
- Datasets or derived audio committed to git, or anything that redistributes licensed data.
- Results that silently mix `es-ES` and `es-419`.
- Runs that cannot be reproduced because the clip list, dataset revision or engine versions are unpinned.

## Constraints

- macOS 15+, Swift 6, Xcode on the Mac mini. Follow the F8.5.0 workflow:
  - branch off `main`, then PR;
  - `just` as the single entry point;
  - test tiers set by `TC_TEST_TIER`;
  - a missing prerequisite fails the run, never skips it.
- Build on the existing test support instead of duplicating it:
  - `TranslateCallTests/Support/`: `FileAudioSource`, `Fixtures`, `WordErrorRate`, `RecordingOutput`, `LatencyReport`;
  - `SplicedSpeech`;
  - the integration tier.

  `LatencyReport` / `latency.json` (REQ-W-24) gets superseded or extended, never left as a second, conflicting format.
- Real-time pacing is required for latency runs, because the VAD and turn timing depend on wall-clock time. A full run therefore takes about as long as its audio.
- Allowed licences:
  - FLEURS (CC BY 4.0), Common Voice 27.0 es (CC0, local archive; es-ES source), Smart Turn v3 test (CC BY 4.0) and NTREX (CC BY-SA 4.0) are usable. VoxPopuli (CC0) was tried and dropped for phase 1 because its segments lack lead/tail silence.
  - Europarl-ST may be used only after its licence is confirmed.
  - Downloads go to a local cache outside git; only manifests (clip ids, dataset revision, checksums) are versioned.
- Data formats, the dataset manifest, the result schema and the reporting/compare tooling must not depend on macOS, so a future Windows build could produce comparable runs. Only the runner that drives the app is macOS-specific.
- UI strings stay English; specs are English; the user is addressed in Spanish.

## Data plan, phase 1

| Set | Variant / language | Source | Gives | Used for |
|---|---|---|---|---|
| FLEURS test, ES/EN common sentence ids | `es-419`, `en` | `google/fleurs` (CC BY) | Read speech, transcript, N-way parallel reference translations | Latency, WER, translation quality (es-419↔en, en→es) |
| Spain Spanish read/semi-spontaneous | `es-ES` | Common Voice 27.0 es, `test` split, Spain accents only (local archive; VoxPopuli was tried and dropped) | Audio + transcript, no translation | Latency, WER, cuts on Spain Spanish |
| Text-only MT | es, en | FLEURS text, NTREX | Reference translations | Translation quality of the MT stage alone |
| End of turn | es, en | Smart Turn v3 test, filtered to spa/eng | Complete/incomplete labels, mid-utterance fillers | Premature-cut rate of today's VAD; base for project 2 |
| Own recordings | `es-ES` (user), `en` (user, non-native, labelled as such) | Scripts prepared by Claude, read aloud by the user | Long sentences, mid-sentence hesitations, turns that end vs. turns that pause, multi-sentence turns; with reference translations written by Claude and checked by the user | Cuts, end of turn and latency on realistic delivery |

Notes:
- Translation quality for `es-ES` audio is measured on the STT output against references where they exist (own recordings), plus the shared text references, since MT references do not depend on the accent. This is Claude's reading and should be checked.
- The own-recording set is small: about 40 prompts per language at first. It grows with more speakers as the project scales.

## Metrics

- **Latency per utterance**, all measured from the real end of speech:
  - VAD end of turn;
  - STT final;
  - translation done;
  - first TTS audio buffer scheduled;
  - total.

  Reported as p50/p90 per pair and variant, plus the cold first-sentence case separately.
- **WER** of STT against the reference transcript, using the existing normalisation (case, diacritics, punctuation).
- **Cut rate:** the share of reference sentences that the VAD split before the speaker finished, and the share of turns merged that should have closed.
- **Translation quality:** a string metric (chrF++) for every run, and a learned metric (COMET-class) for full runs only.
- **Run metadata:**
  - commit and dirty flag;
  - machine model and macOS version;
  - engines selected and their model versions;
  - settings such as the pause length;
  - dataset manifest hash.

## Claude's calls (not confirmed by the user — check while reading)

- **Engine profiles (decided by the user, 2026-10-17, option A).** Two pinned profiles are measured, both fully offline, and both are gated with thresholds. The runner forces each profile explicitly; it never relies on saved user preferences or on what happens to be downloaded.
  - **"Basic"** is a fresh-install Mac: Apple Speech, Apple Translation and system AVSpeech voices.
  - **"Best local"** uses:
    - Parakeet for English STT;
    - the best available local STT for Spanish;
    - Kokoro for English TTS;
    - the user's cloned voice (Qwen3-TTS) where it applies.

  A missing model in a profile fails the run. Edge TTS (cloud) is measured only on demand and only for information, never in gated runs.

  An optional engine matrix, forcing any given STT/TTS, exists for ad-hoc comparisons.
- **Ground-truth speech end.** Computed once per clip offline, from an energy/VAD trim of the source audio or a forced alignment, and stored in the manifest. It is never the WAV length.
- **Production instrumentation.** The app gets a per-utterance pipeline trace: stage timestamps carried with each utterance, also emitted as `os_signpost` for Instruments. The harness reads the same trace that a future in-app latency indicator (UI thread) would use. This touches production code and needs care for the audio path.
- **Incoming direction.** A file-backed `SystemAudioCapture` lets both directions be driven from files. Phase 1 measures each direction alone; overlapping two-way talk is later.
- **Two run sizes:**
  - **PR tier:** about 20–30 clips per direction, real-time paced, a few minutes in `just pr`, quality gates only. Latency on a shared dev machine is too noisy to gate PRs.
  - **Full tier:** every clip, on demand (`just bench`), with the latency verdicts.
- **Thresholds**, starting points to tune after the first baseline:
  - p50 latency regression > 10 % ❌;
  - p90 latency regression > 15 % ❌;
  - WER up > 2 points ❌;
  - chrF++ down > 2 points ❌;
  - cut rate > 5 % ❌ (report S2 criterion).
- **Tooling split.** The runner is Swift inside the test target (it has to drive the app's code). Dataset fetching, manifest building, compare and HTML report are Python scripts run with `uv`, behind `just` recipes. They are cross-platform and have mature metric libraries (sacrebleu, COMET).
- **Cache location** is outside the repo (for example `~/Library/Caches/TranslateCallBench/`), overridable by an env var.
- **HTML report** is a local file by default. Publishing it as a private page is optional, per run.
- **TTS quality** is out of scope for phase 1 metrics. Back-transcribing TTS output for an intelligibility check is a later addition.
- **Recording own clips.** The user records with any recorder at 48 kHz WAV following a prompt sheet; a script ingests, normalises, aligns and checks the clips. A dedicated recording UI is not built.

## Settled after the builder check (Claude's calls)

- **Headline number.** Total latency, from the real end of speech to the first TTS buffer scheduled, is the headline and the number project 2 optimises. The latency verdicts apply to it; per-stage figures are diagnostic only.
- **Production code changes are in scope**, kept small and reviewed. They cover:
  - the per-utterance trace and signposts;
  - a file-backed `SystemAudioCapture`;
  - whatever seam lets `AudioCoordinator.start()` run with file sources in place of the mic and the call app.

  "The real path" means the production `AudioCoordinator`, VAD, STT, translation and TTS objects, with only the audio sources and sinks swapped. The instrumentation lands as the first task(s) of the feature, reviewed with opus like other audio-path work.
- **Where the baseline lives.**
  - The baseline is a small results-only JSON, committed under a bench directory in the repo. It has no audio.
  - Re-baselining is an explicit `just` recipe, done in its own commit or PR with a reason line. Typical reasons: a deliberate trade-off, or a macOS update that changes Apple's models.
  - Run history stays local.
- **PR tier and the cache.** `just pr` runs on the Mac mini only (F8.5.0 D-4).
  - The PR tier uses a small, checksum-pinned subset (target under ~150 MB), fetched automatically on first use and cached.
  - A missing cache triggers the fetch. If the fetch fails, the run fails.
  - The PR tier adds a few minutes of real-time audio.
- **`es-ES` translation quality before the own recordings exist.** Phase 1 is not blocked.
  - `es-ES` audio gets latency, WER and cut metrics.
  - chrF++/COMET come from FLEURS (`es-419`, `en`) and the text references.
  - `es-ES` translation quality joins the baseline when the own recordings land, as a re-baseline.
- **Licences also cover metric models and gated data.**
  - Only commercially usable metric models are allowed: `Unbabel/wmt22-comet-da` (Apache 2.0) is fine; CometKiwi and XCOMET (non-commercial) are not.
  - Common Voice 27.0 es (local archive) is the `es-ES` source; VoxPopuli was tried and dropped.
  - Common Voice needs a one-time manual download by the user (terms accepted on Mozilla Data Collective, no API key). The fetch step fails clearly, naming the path and the download page, when the archive is missing.

## Left to the builder

- Exact JSON result schema and its versioning, and the migration from `latency.json`.
- How the runner drives `AudioCoordinator` end to end (test seams, fakes for the audio outputs) without changing user-visible behaviour.
- Which FLEURS / Common Voice clip ids form the PR subset and the full set (fixed seed, pinned in the manifest).
- Forced-alignment or trim method for the ground-truth speech end.
- HTML report layout and charting library.
- Prompt sheet contents for the own recordings, within the goals above.
