# F6.1 — FluidAudio Parakeet STT: Requirements

> **Feature**: F6.1 — FluidAudio Parakeet STT Integration
> **Milestone**: M6 — Enhanced STT/TTS
> **Status**: DRAFT
> **Author**: SDD Process
> **Date**: 2026-03-11

---

## 1. Overview

Integrate FluidAudio's Parakeet TDT (Token-and-Duration Transducer) model as a second, high-accuracy STT engine for English. Parakeet runs fully on-device via CoreML on Apple Silicon, providing superior accuracy over Apple SFSpeechRecognizer for English speech — especially with accents, proper nouns, and technical vocabulary. Apple Speech remains the engine for all non-English languages.

### 1.1 Scope

- **In scope**: Model download/cache management; `ParakeetSpeechService` conforming to the existing `SpeechRecognizerService` protocol; per-language engine selection; fallback logic; A/B performance metrics; UI controls.
- **Out of scope**: Streaming EOU-based VAD replacement (future F6.x); custom vocabulary boosting; multi-language Parakeet variants; on-the-fly model switching mid-utterance.

### 1.2 Key Constraints

| Constraint | Value | Source |
|------------|-------|--------|
| Parakeet language | English only (`en-*` locales) | Parakeet TDT model card |
| Sample rate | 16 kHz mono PCM | `ASRConstants.sampleRate` |
| Max segment duration | 15 s (240 000 samples) | `ASRConstants.maxDurationSeconds` |
| Model size (CoreML) | ~800 MB (v3) | FluidAudio repo |
| Apple Silicon required | M1 or later | CoreML ANE dependency |

---

## 2. Functional Requirements

### 2.1 Model Lifecycle

**REQ-PAR-01** — WHEN Parakeet is selected as the STT engine for the first time THEN the system SHALL present a model download sheet displaying an indeterminate progress spinner and the estimated download size before any transcription is attempted.

**REQ-PAR-02** — WHEN model download completes THEN the system SHALL cache the model in `~/Library/Application Support/FluidAudio/Models/` using `AsrModels.downloadAndLoad()` and SHALL NOT re-download on subsequent launches.

**REQ-PAR-03** — IF model download fails due to a network error THEN the system SHALL display an error alert with a "Retry" action and SHALL automatically revert the engine selection to Apple Speech until a successful download occurs.

**REQ-PAR-04** — WHEN the app launches and Parakeet was previously selected THEN the system SHALL attempt to load the model from cache using `AsrModels.loadFromCache()` without blocking the main thread.

**REQ-PAR-05** — WHEN model loading from cache fails (corrupted or missing files) THEN the system SHALL silently fall back to Apple Speech, log the error, and set `parakeetAvailable = false` so the UI can indicate the degraded state.

**REQ-PAR-06** — WHEN the user explicitly requests a model re-download (via Settings) THEN the system SHALL delete the cached model and restart the download flow (REQ-PAR-01).

### 2.2 Transcription

**REQ-PAR-07** — WHEN a `SpeechSegment` is submitted for transcription and the Parakeet engine is active THEN `ParakeetSpeechService` SHALL transcribe it using `AsrManager.transcribe([Float])` and return a `TranscriptionResult` conforming to the existing `SpeechRecognizerService` protocol.

**REQ-PAR-08** — WHEN transcription completes THEN the returned `TranscriptionResult.confidence` SHALL map directly from `ASRResult.confidence` (both are `Float` in [0, 1]).

**REQ-PAR-09** — IF `TranscriptionResult.confidence` is below `STTConfiguration.minimumConfidence` (default 0.60) THEN the system SHALL discard the result and emit no update (same behaviour as `AppleSpeechService`).

**REQ-PAR-10** — WHEN a speech segment exceeds 15 seconds THEN `ParakeetSpeechService` SHALL truncate it to the first 240 000 samples, log a warning, and proceed with transcription rather than failing.

**REQ-PAR-11** — IF `AsrManager.transcribe` throws `ASRError.notInitialized` THEN `ParakeetSpeechService` SHALL rethrow as `STTError.failure("parakeet_not_ready")` so the pipeline error-handling logic can recover.

**REQ-PAR-12** — WHILE `ParakeetSpeechService` is transcribing a segment THEN it SHALL NOT accept a concurrent second segment — it SHALL enqueue the second segment and process it sequentially (actor isolation guarantees this).

### 2.3 Language Selection & Fallback

**REQ-PAR-13** — WHEN the user selects Parakeet as the STT engine AND the active source locale is not an English locale (`en-*`) THEN the system SHALL automatically use Apple Speech for that locale without changing the user preference.

**REQ-PAR-14** — WHEN `ParakeetSpeechService.setLocale(_:)` is called with a non-English locale THEN it SHALL throw `STTError.languageUnavailable` so the `AudioCoordinator` can route to `AppleSpeechService` instead.

**REQ-PAR-15** — WHEN the source language is switched from English to a non-English locale while Parakeet is selected THEN the `STTEngineSelector` SHALL transparently activate `AppleSpeechService` and display a badge "Parakeet: English only — using Apple Speech".

**REQ-PAR-16** — WHEN the source language returns to an English locale THEN the `STTEngineSelector` SHALL automatically reactivate Parakeet (if the model is available).

### 2.4 Engine Selection

**REQ-PAR-17** — WHEN the user selects an STT engine in the UI THEN the selection SHALL be persisted in `UserDefaults` under key `tlk.stt.engine` and restored on next launch.

**REQ-PAR-18** — IF no engine preference has been saved THEN the system SHALL default to Apple Speech (preserving M5 behavior).

**REQ-PAR-19** — WHEN Parakeet is unavailable (model not downloaded, device not Apple Silicon) THEN the engine selector UI SHALL disable the Parakeet option and show a tooltip explaining why.

### 2.5 A/B Performance Metrics

**REQ-PAR-20** — WHEN any transcription completes (regardless of engine) THEN the system SHALL record an `STTMetrics` entry containing: engine used, transcription latency (ms), confidence score, segment duration (ms), and timestamp.

**REQ-PAR-21** — WHEN the user opens the metrics panel THEN the system SHALL display average latency and average confidence per engine over the last 50 transcriptions.

**REQ-PAR-22** — Metrics SHALL be stored in memory only (no persistence to disk) and SHALL be cleared on app restart.

---

## 3. Non-Functional Requirements

### 3.1 Performance

**REQ-PAR-NF-01** — Parakeet transcription latency SHALL be ≤ 800 ms for a 5-second speech segment on Apple M1 hardware (RTFx ≥ 6×).

**REQ-PAR-NF-02** — Model loading from cache SHALL complete in ≤ 5 seconds on M1 hardware.

**REQ-PAR-NF-03** — Parakeet model SHALL NOT be loaded into memory when Apple Speech is the active engine (lazy loading required).

**REQ-PAR-NF-04** — `ParakeetSpeechService` deallocation SHALL call `AsrManager.cleanup()` to release CoreML model memory.

### 3.2 Reliability

**REQ-PAR-NF-05** — The pipeline SHALL NOT crash if the Parakeet model fails to load; Apple Speech SHALL be used transparently.

**REQ-PAR-NF-06** — `ParakeetSpeechService` SHALL be robust to `AVAudioPCMBuffer` segments with a non-16kHz sample rate — it SHALL resample or throw `STTError.failure("invalid_sample_rate")` with a clear message.

### 3.3 Privacy

**REQ-PAR-NF-07** — All transcription SHALL be performed on-device. No audio data or transcriptions SHALL be sent over the network (enforced by CoreML; no network entitlement for inference).

### 3.4 Compatibility

**REQ-PAR-NF-08** — `ParakeetSpeechService` SHALL conform to the `SpeechRecognizerService` protocol without any protocol changes, preserving full backward compatibility with `AudioCoordinator` and `AudioViewModel`.

---

## 4. Acceptance Criteria

| ID | Criterion | How Validated |
|----|-----------|---------------|
| AC-01 | Parakeet transcribes English speech with measurably higher confidence than Apple Speech on the same segment | Unit test comparing both engines on a 5 s reference audio file |
| AC-02 | Non-English locale automatically routes to Apple Speech | Unit test: set locale to `fr-FR`, verify `AppleSpeechService` is used |
| AC-03 | Model download shows progress UI; persists across restarts | Manual + UI snapshot test |
| AC-04 | Network failure during download reverts engine to Apple Speech | Unit test with mock download that throws |
| AC-05 | Transcription latency ≤ 800 ms on M1 (5-second segment) | Performance test with `clock()` measurement |
| AC-06 | `ParakeetSpeechService` conforms to `SpeechRecognizerService` without protocol changes | Compiler check (protocol conformance) |
| AC-07 | Metrics panel shows per-engine avg latency and confidence | UI test: transcribe 3 segments per engine, verify values shown |
| AC-08 | App does not crash when model files are deleted mid-session | Unit test: delete cache after load, submit segment |

---

## 5. Out of Scope (Explicitly Deferred)

- **Streaming EOU integration**: `StreamingEouAsrManager` replaces VAD — deferred to F6.3.
- **Vocabulary boosting / context biasing**: Custom vocabulary injection via `CtcModels` — deferred to M8.
- **Multi-speaker diarisation**: Not supported by Parakeet TDT v3.
- **Parakeet for non-English languages**: No multilingual Parakeet model is available at this time.
- **Model size selection** (tiny/large trade-off): Only v3 TDT 0.6B is bundled; model selection UI deferred to M8.
