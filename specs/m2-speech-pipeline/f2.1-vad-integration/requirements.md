# F2.1: VAD Integration — Requirements

**Feature**: Voice Activity Detection Integration (FluidAudio Silero + Energy fallback)
**Milestone**: M2 — Speech Pipeline
**Status**: DRAFT — awaiting Gate 1 review
**Date**: 2026-03-07
**Author**: Claude + Sergio

---

## 1. Context

AudioManager (F1.2) produces two `AsyncStream<AVAudioPCMBuffer>` streams:
- `audioStream48kHz` — raw capture at 48 kHz stereo (for routing)
- `audioStream16kHz` — downsampled 16 kHz mono Float32 (for ML models)

VAD consumes `audioStream16kHz` and acts as a **gatekeeper**: it must detect speech boundaries and emit complete utterances to STT (F2.2), suppressing noise-only segments. Without VAD, STT would run continuously and waste CPU/battery.

The primary VAD engine is FluidAudio's Silero CoreML port (already in the SPM graph). A simple energy-based fallback must be available for offline use or when the model is not yet downloaded.

---

## 2. Definitions

| Term | Definition |
|------|-----------|
| **Utterance** | A continuous segment of speech bounded by silence. Unit of work for STT. |
| **VAD chunk** | 4096 samples at 16 kHz = 256 ms of audio. The Silero model's native processing unit. |
| **Speech start** | First VAD chunk where speech probability ≥ threshold, after a silence or cold start. |
| **Speech end** | Moment when silence has persisted for ≥ `minSilenceDuration` after speech. |
| **Speech probability** | Float in [0, 1] output by the Silero model per 4096-sample chunk. |
| **Energy level** | RMS power of a PCM buffer, used by the energy-based fallback. |

---

## 3. Functional Requirements

### 3.1 VADService Protocol

**REQ-VAD-01**: The system SHALL expose a `VADService` protocol that decouples the VAD interface from its implementation, enabling substitution between Silero and energy-based engines.

**REQ-VAD-02**: WHEN `VADService` is initialized THEN it SHALL accept an `AsyncStream<AVAudioPCMBuffer>` at 16 kHz as its audio source.

**REQ-VAD-03**: The `VADService` protocol SHALL expose a `speechSegments: AsyncStream<SpeechSegment>` (or equivalent `AsyncSequence`) for consumers to iterate over complete utterances.

**REQ-VAD-04**: `SpeechSegment` SHALL carry the PCM audio samples (as `[Float]` at 16 kHz) of the complete utterance, enabling STT to process it without accessing any shared buffer.

### 3.2 Silero Implementation (primary engine)

**REQ-VAD-10**: WHEN the Silero model is available THEN `SileroVADService` SHALL use `VadManager.processStreamingChunk(_:state:config:)` to analyze incoming audio in 4096-sample chunks.

**REQ-VAD-11**: WHEN `audioStream16kHz` buffers arrive THEN `SileroVADService` SHALL accumulate them in an internal ring buffer until at least 4096 samples are available, then process one VAD chunk.

**REQ-VAD-12**: WHEN a `VadStreamEvent.speechStart` event is emitted by `VadManager` THEN `SileroVADService` SHALL begin accumulating audio into an utterance buffer, including the pre-start context samples indicated by `sampleIndex`.

**REQ-VAD-13**: WHEN a `VadStreamEvent.speechEnd` event is emitted THEN `SileroVADService` SHALL yield a `SpeechSegment` containing all accumulated audio up to the end boundary and reset the utterance buffer.

**REQ-VAD-14**: WHEN an utterance exceeds `maxSpeechDuration` (default: 14 s) THEN the system SHALL forcibly close it and yield the accumulated audio, preventing unbounded buffer growth.

**REQ-VAD-15**: IF the Silero model is not yet downloaded THEN `SileroVADService` initialization SHALL download it from HuggingFace (`FluidInference/silero-vad-coreml`) using `DownloadUtils.loadModels(.vad, ...)` and SHALL surface download progress to the caller.

**REQ-VAD-16**: WHILE `SileroVADService` is processing audio THEN it SHALL maintain stateful `VadStreamState` across chunks, enabling hysteresis (speech/silence thresholds differ to avoid chattering).

### 3.3 Energy Fallback Implementation

**REQ-VAD-20**: `EnergyVADService` SHALL implement the same `VADService` protocol without requiring any model download.

**REQ-VAD-21**: WHEN an audio buffer's RMS power exceeds `energyThreshold` (default: −40 dBFS) for ≥ `minSpeechDuration` (default: 150 ms) THEN `EnergyVADService` SHALL consider speech started.

**REQ-VAD-22**: WHEN RMS power drops below `energyThreshold` for ≥ `minSilenceDuration` (default: 750 ms) THEN `EnergyVADService` SHALL consider speech ended and yield the utterance.

**REQ-VAD-23**: `EnergyVADService` SHALL use the same `SpeechSegment` output type as `SileroVADService`, so all consumers are engine-agnostic.

### 3.4 Engine Selection

**REQ-VAD-30**: `VADServiceFactory` SHALL select the Silero engine by default and fall back to the energy engine if the Silero model fails to load.

**REQ-VAD-31**: The factory SHALL expose a `preferredEngine: VADEngine` configuration (`.silero` / `.energy`) that can be overridden at runtime (e.g., for testing or low-memory situations).

### 3.5 Lifecycle

**REQ-VAD-40**: WHEN `startCapture()` is called on AudioManager THEN the VAD service SHALL be activated and begin consuming `audioStream16kHz`.

**REQ-VAD-41**: WHEN `stopCapture()` is called THEN the VAD service SHALL drain any in-progress utterance buffer, yield a final segment if ≥ `minSpeechDuration` of speech was accumulated, and stop consuming audio.

**REQ-VAD-42**: WHILE no speech is detected THEN the VAD service SHALL NOT yield any segment. Audio is silently discarded.

### 3.6 UI Feedback

**REQ-VAD-50**: `VADService` SHALL expose a `@Published var isSpeechActive: Bool` (or equivalent Combine publisher) that the UI can observe to display the current VAD state.

**REQ-VAD-51**: WHEN speech starts THEN `isSpeechActive` SHALL be set to `true` within 300 ms of the first detected speech boundary.

**REQ-VAD-52**: WHEN speech ends THEN `isSpeechActive` SHALL be set to `false` after the utterance is yielded.

---

## 4. Non-Functional Requirements

### 4.1 Latency

**REQ-NFR-01**: VAD processing latency per 256 ms chunk SHALL be < 20 ms on Apple M1 (i.e., real-time factor > 12×). This matches the PoC2 measurement of < 0.01 ms/chunk for energy VAD; Silero is expected to be in the 1–10 ms range on Neural Engine.

**REQ-NFR-02**: Speech start detection latency (time from first voiced frame to `speechStart` event) SHALL be ≤ 512 ms (two VAD chunks + state machine delay).

### 4.2 Accuracy

**REQ-NFR-03**: On synthetic test audio (alternating 1 s speech / 1 s silence sine patterns), both Silero and energy VAD SHALL achieve ≥ 90% speech detection rate and ≤ 10% false positive rate.

**REQ-NFR-04**: Utterance boundary precision (start/end within ± 300 ms of actual boundary) SHALL be ≥ 85% on a held-out test set of 20 real speech samples.

### 4.3 Privacy

**REQ-NFR-05**: No audio samples SHALL leave the device. The Silero model is loaded locally (CoreML). The one-time download is model weights only, not user audio.

**REQ-NFR-06**: The utterance buffer SHALL be cleared immediately after `SpeechSegment` is yielded. No audio SHALL be retained beyond the current utterance.

### 4.4 Resource Usage

**REQ-NFR-07**: VAD processing SHALL use ≤ 5% CPU sustained on Apple M1 (measured via Instruments Energy Log). The Silero model SHALL run on Neural Engine (`computeUnits: .cpuAndNeuralEngine`).

**REQ-NFR-08**: The utterance buffer SHALL be bounded: if speech exceeds `maxSpeechDuration` (14 s), the segment SHALL be forcibly emitted (REQ-VAD-14), preventing unbounded memory growth.

### 4.5 Swift 6 / Concurrency

**REQ-NFR-09**: `VADService` and both implementations SHALL compile with Swift 6 strict concurrency (`-strict-concurrency=complete`) without warnings.

**REQ-NFR-10**: Buffer accumulation and VAD inference SHALL run off the main actor (on a background task / nonisolated context). UI publishers SHALL be dispatched to `@MainActor`.

---

## 5. Constraints

| Constraint | Value |
|-----------|-------|
| Platform | macOS 15.0+ |
| Language | Swift 6.0 strict concurrency |
| Primary VAD engine | FluidAudio `VadManager` (already in SPM graph) |
| VAD model | `silero-vad-unified-256ms-v6.0.0.mlmodelc` from `FluidInference/silero-vad-coreml` |
| Input format | 16 kHz, mono, Float32 (PCM) |
| VAD chunk size | 4096 samples = 256 ms (Silero model constraint) |
| Audio source | `AudioManager.audioStream16kHz: AsyncStream<AVAudioPCMBuffer>` |
| No new SPM dependencies | Energy fallback uses Accelerate only (already linked) |

---

## 6. Out of Scope (F2.1)

- STT integration — F2.2 consumes `SpeechSegment` output but is a separate feature
- TTS — F2.3
- Language detection — will be handled in F2.2 or F3.2
- Continuous streaming partial-results — VAD yields complete utterances only; partial text is an STT concern
- Diarization (speaker identification) — M6+

---

## 7. Acceptance Criteria (Gate 4 — Validation)

These criteria translate directly into unit/integration tests in `TranslateCallTests/`:

| ID | Criterion | Test |
|----|-----------|------|
| AC-01 | `SileroVADService` loads model and emits ≥ 1 segment from 3-second test audio containing speech | `testSileroVADDetectsSpeech()` |
| AC-02 | `SileroVADService` emits 0 segments from 3-second silent test audio | `testSileroVADIgnoresSilence()` |
| AC-03 | `EnergyVADService` detects speech onset within 512 ms on synthetic audio | `testEnergyVADDetectsSpeechStart()` |
| AC-04 | `EnergyVADService` emits 0 segments from silent audio | `testEnergyVADIgnoresSilence()` |
| AC-05 | `SpeechSegment` audio is non-empty and matches expected duration (± 300 ms) | `testSpeechSegmentDuration()` |
| AC-06 | `isSpeechActive` transitions true → false within 300 ms of speech end | `testVADStatePublisher()` |
| AC-07 | Processing 4096-sample chunk takes < 20 ms on current device | `testVADPerformance()` |
| AC-08 | Buffer does not grow unbounded for 15-second continuous speech (segments forcibly emitted) | `testMaxSpeechDurationSplit()` |
| AC-09 | `VADServiceFactory` returns `EnergyVADService` when `preferredEngine = .energy` | `testFactoryEngineSelection()` |
| AC-10 | All VAD code compiles with 0 warnings under Swift 6 strict concurrency | CI build check |

---

## 8. Open Questions (to resolve before design.md)

1. **Buffer type for utterance**: Should `SpeechSegment` carry `[Float]` samples or `AVAudioPCMBuffer`?
   - `[Float]` is simpler and `Sendable` without conformance boilerplate. `AVAudioPCMBuffer` is what Apple Speech (`SFSpeechAudioBufferRecognitionRequest`) can consume directly.
   - **Preferred**: `[Float]` for VAD→STT handoff (STT wraps in `AVAudioPCMBuffer` locally). But needs confirmation.

2. **Where does VAD live in the object graph?** Options:
   - (A) `AudioManager` owns and drives `VADService` — keeps all audio processing centralized
   - (B) `VADService` is a standalone actor that subscribes to `AudioManager.audioStream16kHz` — cleaner separation of concerns, easier to test in isolation
   - **Preferred**: Option B. AudioManager stays focused on capture/routing; VAD is an independent consumer.

3. **Model download UX**: On first launch, downloading the Silero model (~5 MB) requires internet. Should the UI show a progress indicator? Or silently fall back to energy VAD while downloading in background?
   - **Preferred**: Fall back to energy VAD immediately, download Silero in background, switch automatically when ready.

4. **VAD config exposure**: Should `VadSegmentationConfig` be directly exposed in `VADService`, or wrapped in a `TranslateCallVADConfig` struct to insulate from FluidAudio API changes?
   - **Preferred**: Wrap in `VADConfiguration` to avoid leaking third-party types into our public interface.

---

*Gate 1 Review: human must approve this document before design.md is written.*
