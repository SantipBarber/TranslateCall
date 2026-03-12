# F6.2 — MLX-Audio Kokoro TTS: Requirements

> **Feature**: F6.2 — MLX-Audio Kokoro TTS Integration
> **Milestone**: M6 — Enhanced STT/TTS
> **Status**: DRAFT
> **Author**: SDD Process
> **Date**: 2026-03-12

---

## 1. Overview

Integrate a high-quality on-device TTS engine (Kokoro or equivalent MLX-based model) as a second synthesis option alongside the existing `AVSpeechService`. The new engine runs fully on Apple Silicon via CoreML/MLX, producing more natural-sounding speech than `AVSpeechSynthesizer` Premium voices — particularly for English. `AVSpeechService` remains the engine for all languages not supported by the new model and serves as the automatic fallback when model loading fails.

### 1.1 Scope

- **In scope**: Model download/cache management; a new `SynthesisService`-conforming actor; per-language engine selection; fallback logic; voice selection UI with audio preview; A/B latency metrics; integration into the existing `AudioCoordinator` pipeline.
- **Out of scope**: Voice cloning or speaker conditioning (F7.x); multi-speaker diarisation; custom voice fine-tuning; streaming token-by-token synthesis (future F6.x); SSML markup support.

### 1.2 Key Constraints

| Constraint | Value | Source |
|------------|-------|--------|
| Initial language support | English (`en-*` locales) | Kokoro v0.19 model card |
| Sample rate output | 24 kHz or 16 kHz mono PCM (model-dependent) | To be confirmed in design phase |
| Model size | ~300 MB (fp16 CoreML) | Estimated from Kokoro-82M parameter count |
| Apple Silicon required | M1 or later (ANE/GPU path) | MLX runtime requirement |
| Minimum synthesis latency target | ≤ 600 ms for a 10-word sentence on M1 | Latency budget (same as `AVSpeechService` target) |

---

## 2. Functional Requirements

### 2.1 Model Lifecycle

**REQ-KOK-01** — WHEN the user selects Kokoro as the TTS engine for the first time THEN the system SHALL present a model download sheet displaying an indeterminate progress spinner and the estimated download size before any synthesis is attempted.

**REQ-KOK-02** — WHEN model download completes THEN the system SHALL cache the model files under `~/Library/Application Support/TranslateCall/Models/Kokoro/` and SHALL NOT re-download on subsequent launches.

**REQ-KOK-03** — IF model download fails due to a network or I/O error THEN the system SHALL display an error alert with a "Retry" action and SHALL automatically revert the engine selection to AVSpeech until a successful download occurs.

**REQ-KOK-04** — WHEN the app launches and Kokoro was previously selected THEN the system SHALL attempt to load the model from cache without blocking the main thread or the audio pipeline.

**REQ-KOK-05** — WHEN model loading from cache fails (corrupted or missing files) THEN the system SHALL silently fall back to AVSpeech, log the error, and set `kokoroAvailable = false` so the UI can indicate the degraded state.

**REQ-KOK-06** — WHEN the user explicitly requests a model re-download (via Settings) THEN the system SHALL delete the cached model files and restart the download flow described in REQ-KOK-01.

**REQ-KOK-07** — WHEN Kokoro is unloaded or deactivated THEN the system SHALL release all CoreML/MLX model memory by calling the appropriate cleanup method on the model manager.

### 2.2 Synthesis

**REQ-KOK-08** — WHEN `speak(text:locale:)` is called on `KokoroSpeechService` THEN it SHALL synthesize audio using the loaded Kokoro model, convert the output to the correct `AVAudioFormat` for the output device, and play it through the configured `AVAudioPlayerNode`.

**REQ-KOK-09** — WHEN synthesis completes THEN `KokoroSpeechService` SHALL emit `false` on `isSpeakingStream`, matching the existing `SynthesisService` protocol contract.

**REQ-KOK-10** — WHEN `stopSpeaking()` is called THEN `KokoroSpeechService` SHALL immediately stop playback, flush any queued synthesis buffers, and transition `isSpeakingStream` to `false`.

**REQ-KOK-11** — IF the Kokoro model is not yet loaded when `speak(text:locale:)` is called THEN `KokoroSpeechService` SHALL throw `STSError.engineStartFailed` so the `AudioCoordinator` can fall back to AVSpeech for that utterance.

**REQ-KOK-12** — WHEN a synthesis request arrives while a previous utterance is still playing THEN `KokoroSpeechService` SHALL queue the new request and process it after the current utterance finishes (matching `AVSpeechService` queue behaviour).

### 2.3 Language Support & Fallback

**REQ-KOK-13** — WHEN the user selects Kokoro as the TTS engine AND the active target locale is not supported by the model THEN the system SHALL automatically use AVSpeech for that locale without changing the user's engine preference.

**REQ-KOK-14** — WHEN the target language is switched to an unsupported locale while Kokoro is selected THEN the `TTSEngineSelector` SHALL transparently activate `AVSpeechService` and display a badge indicating "Kokoro: [language] not supported — using AVSpeech".

**REQ-KOK-15** — WHEN the target language returns to a Kokoro-supported locale THEN the `TTSEngineSelector` SHALL automatically reactivate Kokoro (if the model is loaded and available).

### 2.4 Voice Selection

**REQ-KOK-16** — WHEN the Kokoro engine is active THEN the UI SHALL expose a voice selector listing all voices available for the current target locale (minimum 1 voice for English at launch).

**REQ-KOK-17** — WHEN the user selects a voice THEN `KokoroSpeechService` SHALL use that voice identifier for all subsequent synthesis calls and SHALL persist the selection in `UserDefaults` under key `tlk.tts.kokoro.voice`.

**REQ-KOK-18** — WHEN the user taps a "Preview" button next to a voice THEN the system SHALL synthesize a short fixed sample phrase ("Hello, this is how I sound.") and play it through the output device so the user can audition the voice before committing.

**REQ-KOK-19** — IF no voice preference has been saved THEN the system SHALL default to the first available voice for the active locale.

### 2.5 Engine Selection

**REQ-KOK-20** — WHEN the user selects a TTS engine in the UI THEN the selection SHALL be persisted in `UserDefaults` under key `tlk.tts.engine` and restored on next launch.

**REQ-KOK-21** — IF no TTS engine preference has been saved THEN the system SHALL default to AVSpeech (preserving M5 behaviour).

**REQ-KOK-22** — WHEN Kokoro is unavailable (model not downloaded, device not Apple Silicon, or loading failed) THEN the engine selector UI SHALL disable the Kokoro option and show a tooltip explaining why.

**REQ-KOK-23** — WHEN the user requests a Kokoro model download THEN the engine selector SHALL expose a `TTSEngineSelector.downloadKokoroModel()` action that triggers the download and reports progress via a `@Published isDownloading: Bool` property.

### 2.6 A/B Performance Metrics

**REQ-KOK-24** — WHEN any synthesis completes (regardless of engine) THEN the system SHALL record a `TTSMetrics` entry containing: engine used, synthesis latency (ms), text length (characters), locale, and timestamp.

**REQ-KOK-25** — WHEN the user opens the metrics panel THEN the system SHALL display average synthesis latency per engine over the last 50 synthesis events.

**REQ-KOK-26** — Metrics SHALL be stored in memory only (no persistence to disk) and SHALL be cleared on app restart.

---

## 3. Non-Functional Requirements

### 3.1 Performance

**REQ-KOK-NF-01** — Kokoro synthesis latency (text-in to first audio sample) SHALL be ≤ 600 ms for a sentence of ≤ 20 words on Apple M1 hardware.

**REQ-KOK-NF-02** — Model loading from cache SHALL complete in ≤ 10 seconds on M1 hardware.

**REQ-KOK-NF-03** — The Kokoro model SHALL NOT be loaded into memory when AVSpeech is the active engine (lazy loading required).

**REQ-KOK-NF-04** — Peak memory footprint for the loaded model SHALL be ≤ 600 MB (fp16 weights + runtime buffers).

### 3.2 Reliability

**REQ-KOK-NF-05** — The pipeline SHALL NOT crash if the Kokoro model fails to load; AVSpeech SHALL be used transparently.

**REQ-KOK-NF-06** — `KokoroSpeechService` SHALL handle empty or whitespace-only text gracefully (no synthesis, no crash, `isSpeakingStream` stays `false`).

**REQ-KOK-NF-07** — `KokoroSpeechService` SHALL handle very long text (> 500 characters) by either truncating with a logged warning or splitting into synthesis chunks, without throwing an unhandled error.

### 3.3 Privacy

**REQ-KOK-NF-08** — All speech synthesis SHALL be performed on-device. No text or audio SHALL be sent over the network (enforced by CoreML/MLX inference; no inference-related network entitlement).

### 3.4 Compatibility

**REQ-KOK-NF-09** — `KokoroSpeechService` SHALL conform to the `SynthesisService` protocol without any protocol changes, preserving full backward compatibility with `AudioCoordinator`.

**REQ-KOK-NF-10** — The new `TTSEngineSelector` class SHALL follow the same `@MainActor ObservableObject` pattern as `STTEngineSelector` and integrate with `AudioViewModel` and `AudioCoordinator` via the same factory-closure pattern.

---

## 4. Acceptance Criteria

| ID | Criterion | How Validated |
|----|-----------|---------------|
| AC-01 | Kokoro synthesises English speech that is rated more natural than AVSpeech Premium in an informal A/B test | Manual listening test by developer |
| AC-02 | Non-supported locale automatically routes to AVSpeech | Unit test: set target locale to `ja-JP`, verify `AVSpeechService` is used |
| AC-03 | Model download shows spinner UI; model persists across restarts | Manual test + unit test for cache path |
| AC-04 | Network failure during download reverts engine to AVSpeech | Unit test with mock downloader that throws |
| AC-05 | Synthesis latency ≤ 600 ms for a 10-word sentence on M1 | Performance test with `clock()` measurement |
| AC-06 | `KokoroSpeechService` conforms to `SynthesisService` without protocol changes | Compiler check |
| AC-07 | Voice preview plays the sample phrase through the output device | Manual test |
| AC-08 | Metrics panel shows per-engine avg synthesis latency | UI test: synthesise 3 sentences per engine, verify values shown |
| AC-09 | App does not crash when model files are deleted mid-session | Unit test: delete cache after load, call `speak()` |
| AC-10 | Memory is released after `deactivate()` is called on `KokoroSpeechService` | Instrument check (Allocations); unit test verifies cleanup called |

---

## 5. Out of Scope (Explicitly Deferred)

- **Voice cloning / speaker conditioning**: Neural voice style transfer — deferred to F7.x.
- **Streaming synthesis**: Token-by-token audio output for ultra-low latency — deferred to a future F6.x.
- **SSML / prosody control**: Markup-based intonation and emphasis — deferred to M8.
- **Non-English Kokoro models**: Additional language packs will be added in F6.x or M8 once multilingual Kokoro variants are production-ready.
- **Model size selection**: Single model variant at launch; quality/size trade-off UI deferred to M8.
- **Pitch and rate controls for Kokoro**: `SynthesisConfiguration.rate` and `.pitchMultiplier` are respected by AVSpeech; mapping to Kokoro inference parameters is deferred until the API is confirmed in design phase.
