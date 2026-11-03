# M9 voice-clone streaming and early end-of-turn — Requirements

> Status: APPROVED (2026-10-31).
> Inputs: latency project 2 root cause (memory `m9-latency-project2-handoff`, probe `TranslateCallTests/Integration/QwenCloneProbeTests.swift`), ui-settings manual test S7 (2026-10-19), `specs/m9-product/benchmark-harness/`, backlog UI-S3.

## Overview

The user's cloned voice works, but in a call each sentence takes ~7 s to start (in-app metrics, Release: Voice Clone mean 7 192 ms over 10 sentences, AVSpeech 435 ms). The user: "así no es funcional". The goal is a fluent conversation with the cloned voice.

Two causes, measured in Release on the Mac mini (M4):
1. `QwenUtteranceSynthesizer` uses mlx-audio's non-streaming `generate`: the whole sentence is generated before anything plays (5.3–7.9 s per sentence with the user's 31 s reference).
2. Qwen3-TTS puts the reference recording's codes and transcript in the prompt of every call, so the time to the first audio grows with the reference length: 0.84 s with the 31 s reference, ~0.33 s with 5–10 s (streaming, `streamingInterval` 0.32).

The rest of the pipeline (end of speech → translated text) takes **~1.4–1.6 s** (bench Basic, Release, run 2026-10-30 `2e6d017`, p50: VAD end-of-turn 750–940 ms, STT 190–250 ms, translation 310–480 ms; AVSpeech first audio ~110 ms; total 1.50–1.75 s). An earlier estimate of ~1.1 s, given to the user during the brainstorm, was wrong (the builder check caught it). Expected end-to-end with the clone: ~2.3 s with streaming and the 31 s reference, ~1.8–1.9 s with a short reference. The user chose both, in one feature.

## Decisions taken (brainstorm 2026-10-30/31)

| ID | Decision |
|----|----------|
| Q-1 | **Target:** end of the user's speech → first audio in the cloned voice under **1.5 s** (p50, Release, bench Best local). The user chose this; it was first framed as streaming-only, and the 1.5 s figure was then shown to need a short reference too. |
| Q-2 | **Streaming and short reference ship together** (user: "Todo"). |
| Q-3 | **The voice preview in Settings › Voices stays non-streaming.** User: the wait there "no molesta"; what matters is the conversation. |
| Q-5 | **The 1.5 s target is an acceptance gate, and the end-of-turn wait is cut in this feature** (user: "B", 2026-10-31). The budget: STT + translation ~0.62 s + clone first chunk ~0.33 s leaves ≤ ~0.55 s for the end-of-turn wait, against ~0.85 s today. |
| Q-6 | **Early processing first; shorter default pause only if needed.** STT and translation start at the first silent chunk, and the user's pause still decides when the sentence is spoken (no new cut risk). If the bench is still ≥ 1.5 s, the default pause drops from 0.6 s to 0.4 s; the user can raise it in Settings (user: "igual por ahora podría valer"). |
| Q-7 | **Semantic end-of-turn (a model that knows where a sentence really ends) is explored apart**: a research report runs in parallel; this feature's tentative/commit design is the hook a turn model would plug into later. |
| Q-4 | **Streaming plan from latency project 2, option A** (chosen 2026-10-18): `generateStream`; 3 s limit to the FIRST chunk, then fallback to AVSpeech; once audio flows, the existing 30 s utterance watchdog is the safety net; `MLXInferenceGate` stays closed for the whole stream. |

## Functional Requirements

### FR-QS.1 — Streaming synthesis in calls

**REQ-QS-01**: During a session, the voice-clone synthesizer SHALL hand each audio chunk to playback as soon as Qwen3-TTS produces it, instead of waiting for the whole sentence.

**REQ-QS-02**: The chunk size SHALL come from one configuration value (`streamingInterval`, seconds of audio per chunk), default **0.32 s**.

**REQ-QS-03**: If no chunk arrives within **3 s** of the synthesis starting (gate wait included), the sentence SHALL be spoken by the fallback voice, as for any primary failure today (REQ-T-20/22, circuit breaker REQ-T-23 unchanged). The 10 s whole-inference limit SHALL no longer apply on the session path.

**REQ-QS-04**: Once the first chunk has arrived, the sentence SHALL NOT be cut by a per-inference timeout; only the playback service's utterance watchdog (30 s, REQ-T-16) applies.

**REQ-QS-05**: An error after some audio has been heard SHALL end the sentence as interrupted (today's behaviour for partial audio); the fallback SHALL NOT repeat a sentence the other side has partly heard.

**REQ-QS-06**: At most one Qwen3-TTS inference SHALL run at a time, process-wide (REQ-T-30…32, backlog T6). The gate SHALL stay closed until the model's generation has really ended, even when the caller has stopped listening (cancel, stop, first-chunk timeout, watchdog). Chunks produced after the caller left SHALL be discarded.

**REQ-QS-07**: `stopSpeaking` (and session stop) SHALL stop the sentence's audio at once, as today; no chunk of a stopped sentence SHALL be scheduled afterwards.

**REQ-QS-07a**: While the gate is held by a generation nobody listens to any more (after a stop, a first-chunk timeout or a watchdog), a new clone sentence SHALL go straight to the fallback without waiting for the gate, and SHALL NOT count toward the circuit breaker.

**REQ-QS-08**: Unloading the model SHALL still wait until no generation is running (design §6 of F8.5.2).

### FR-QS.2 — Short reference recording

**REQ-QS-10**: Creating a voice SHALL offer a **guided short recording**: the app shows a text to read aloud, in a language the user picks (default: the language the user speaks in the current pair, when Qwen supports it; otherwise English). The recording stops automatically at the length limit (REQ-QS-12) and may be stopped earlier by the user.

**REQ-QS-11**: For a guided recording, the shown text SHALL be saved as the voice's transcript. The user SHALL be able to edit it before saving (if they misread a word).

**REQ-QS-12**: The guided text and the length limit SHALL be sized to the reference length fixed by the measurement gate (REQ-QS-30); the planning default is **~8 s of speech** with a **15 s** auto-stop.

**REQ-QS-13**: The guided texts SHALL exist for every language Qwen3-TTS supports in the app (`QwenCloneConfiguration.supportedLanguageList`, 10 languages), written as natural speech of the target length.

**REQ-QS-14**: The current free recording (up to 30 s, transcript typed by the user) SHALL stay available as a secondary option ("Use my own text").

**REQ-QS-15**: Existing voices SHALL keep working unchanged (streaming applies to them too). A voice whose reference is longer than **12 s** SHALL show, in Settings › Voices, a hint that a short recording answers faster, with an action that starts the guided recording. That recording is saved as a **new voice that becomes the active one**; the long voice is kept (the user may delete it). Nothing is converted or deleted automatically.

**REQ-QS-16**: A guided recording SHALL be saveable at its target length: the "too short" save block applies to it with the guided thresholds (design §7.3), not the free mode's 8 s.

### FR-QS.5 — Early processing at the end of a turn

**REQ-QS-40**: When the voice detector sees the first silence after speech, it SHALL hand the utterance so far to speech recognition as a **tentative** utterance, before the pause (`minSilenceDuration`) has elapsed.

**REQ-QS-41**: A tentative utterance SHALL be recognised and translated at once, and its translation held, not spoken nor shown in the transcript.

**REQ-QS-42**: When the pause completes with no new speech, the tentative utterance SHALL be **committed**: its held translation is shown and spoken (as soon as it is ready, if still in progress). The audio, text and timing then match today's single utterance.

**REQ-QS-43**: When speech resumes before the pause completes, the tentative utterance SHALL be **retracted**: its recognition and translation are discarded (cancelled if still running), nothing of it is shown or spoken, and the utterance continues. The next tentative covers the whole utterance from its start.

**REQ-QS-44**: Force-emits at `maxSpeechDuration`, session stop, pause, mute turn and direction switches SHALL behave as today. A retracted or uncommitted tentative SHALL never reach TTS or the transcript.

**REQ-QS-45**: This SHALL work for both voice detectors (Silero and Energy) and every speech-recognition engine, in both directions.

**REQ-QS-46**: **Shorter pause, only if needed.** If, after FR-QS.1–5, bench Best local with a short voice still has total p50 ≥ 1.5 s in any gated direction, the default "Pause to translate" SHALL become **0.4 s** (range unchanged, 0.4–1.2 s). A value the user saved is kept. The bench cut-rate gate applies.

### FR-QS.3 — Measurement

**REQ-QS-20**: The bench (Best local profile, Release) SHALL measure the voice-clone path end to end, closing backlog UI-S3: the clone SHALL actually speak in the run, and the report SHALL name the voice profile and its reference length.

**REQ-QS-21**: The bench SHALL report, for the clone, the gaps in playback: the number of sentences in which a chunk arrived after the audio scheduled before it had finished playing, and the total gap time.

**REQ-QS-23**: The bench SHALL report, per profile and direction, the share of tentative utterances retracted, and the time from the real end of speech to commit.

**REQ-QS-22**: The session log SHALL record, per clone sentence, time to first chunk, total generation time, audio length and gap count (one line, no text content).

### FR-QS.4 — Gates

**REQ-QS-30**: **Measure-first gate (before the short-reference UI is built).** With the probe, in Release, on the Mac mini: time to first chunk, generation speed (tokens/s) and total time, for references of **5, 8 and 10 s** that the user records reading a draft guided text (as plain audio files, design §9), and the 31 s voice for comparison; cold (first after load) and warm. The user listens to the same sentences (Spanish and English) in each length and picks the shortest one that still sounds like them. That length fixes REQ-QS-12. If no length under 31 s sounds right to the user, stop and present options.

**REQ-QS-31**: **Warm-up.** If the gate measures the first inference after load as more than 1.5× slower to first chunk than a warm one, a short warm-up inference SHALL run when the model is loaded for a session (through the gate), so the first real sentence is not cold. Otherwise, no warm-up.

## Non-functional Requirements

**NFR-QS-01 — Latency (acceptance gate, Q-5).** Bench Best local, Release, with a short-reference voice: total latency p50 **< 1.5 s** and p90 **< 2.0 s** per direction where the clone speaks. Checked on a full run before acceptance; PR runs track it. With the user's current 31 s voice: informative only.

**NFR-QS-05 — No new cuts.** Early processing SHALL NOT change cut rate or WER beyond bench noise (it commits on the same pause as before). With REQ-QS-46 applied, the cut-rate gate decides; if it fails, stop and present options.

**NFR-QS-02 — Fluency.** In the same run, gaps (REQ-QS-21) in **≤ 5 %** of clone sentences. Generation in Release is ~1.5–1.8× real time (18–23 tok/s vs 12.5 needed), so chunks should stay ahead of playback after the first.

**NFR-QS-03 — No regression.** `just pr` green; Basic profile verdicts unchanged; existing TTS/gate test suites still pass (adapted only where the session path's timeout semantics change).

**NFR-QS-04 — Quality is judged by ear.** Streaming starts the codec decoder without the reference's context, and a short reference carries less of the voice. The manual checklist SHALL include listening to the clone in a real call (both directions), with the 31 s and the short voice.

## Out of scope

- Streaming in the voice preview (Q-3).
- Caching the reference's encoding across calls (mlx-audio has no public API for it; would need a fork).
- Automatically trimming existing recordings (needs a transcript that matches the cut).
- Semantic end-of-turn detection (Q-7), streaming STT/translation and the other stages (STT, translation, cold start): latency project 2, informed by the research report.
- Debug-build performance: below real time with Qwen; Release is the reference.

## Acceptance

1. Measure-first gate (REQ-QS-30) passed and the reference length chosen by the user.
2. `just pr` green; a full bench Best local run with a short voice meets NFR-QS-01/02/05.
3. Manual checklist passed by the user: a real call, both directions, clone voice fluent; fallback when the model is busy or slow; stop mid-sentence; guided recording in Spanish and English; long-voice hint; hesitations mid-sentence (prompt sheets with pauses) are not cut more than before.
