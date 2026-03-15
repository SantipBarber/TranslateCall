# F7.2 — CSM-1B Voice Cloning Integration: Requirements

> **Feature**: F7.2 — CSM-1B Voice Cloning Integration
> **Milestone**: M7 — Voice Cloning
> **Status**: DRAFT
> **Author**: SDD Process
> **Date**: 2026-03-12
> **Depends on**: F7.1 (Voice Profile Training — COMPLETED)

---

## 1. Overview

Integrate the Sesame CSM-1B (Conversational Speech Model) as a voice-cloning TTS engine. When an active voice profile exists and the user enables voice cloning, translated speech is synthesized in the user's own voice instead of a generic TTS voice. CSM-1B replaces Kokoro/AVSpeech in the outgoing pipeline while the profile is active; the incoming pipeline continues using the standard TTS engine (Kokoro or AVSpeech).

### 1.1 Scope

- **In scope**: CSM-1B model download and lifecycle management; a new `SynthesisService`-conforming actor (`CSMSpeechService`); voice conditioning from the active `VoiceProfile` (F7.1 `Segment` = audio + transcript); integration into `TTSEngineSelector` as a third engine tier; fallback to Kokoro/AVSpeech when CSM is unavailable or the locale is unsupported; inference latency monitoring; memory management (load/unload model on demand).
- **Out of scope**: Voice similarity scoring or quality validation (F7.3); A/B toggle UI and preview (F7.3); per-language voice profile tuning (F7.3); multi-speaker profiles; streaming/chunked synthesis (future optimisation); fine-tuning or training the CSM model; voice profile recording or management (F7.1).

### 1.2 Key Constraints

| Constraint | Value | Source |
|------------|-------|--------|
| Model | CSM-1B (Sesame Conversational Speech Model) | M7 roadmap |
| Model format | MLX SafeTensors (`senstella/csm-1b-mlx` or equivalent) | csm-mlx project |
| Output sample rate | 24 kHz mono | CSM-1B generator |
| Reference audio format | 24 kHz mono Float32 PCM + UTF-8 transcript | F7.1 `VoiceProfile` format (exact match) |
| Language support | English (`en-*` locales) only | CSM-1B training data |
| Apple Silicon required | M1 or later | MLX runtime requirement |
| Minimum RAM for inference | 8 GB (16 GB recommended) | csm-mlx documentation |
| Model size (disk) | ~2 GB (FP16 SafeTensors + Mimi codec) | HuggingFace model card |
| Latency target | ≤ 3 s total pipeline (CSM adds ≤ 1.5 s over Kokoro) | Adjusted from ROADMAP 500ms — see § 1.3 |
| Minimum macOS | 15.0 | Project deployment target |

### 1.3 Latency Realism Note

The ROADMAP M7 acceptance gate states "< 500 ms additional latency" for voice cloning. Community benchmarks for CSM-1B on Apple Silicon report **1–6 seconds** for non-streaming inference and **1–2 seconds** for first audio chunk with streaming. The 500 ms target is not achievable with current CSM-1B weights and hardware.

This requirements document adjusts the latency target to **≤ 1.5 seconds additional** over Kokoro (i.e., ≤ 3 s total end-to-end). This is a pragmatic compromise: voice cloning adds meaningful value even at higher latency, and the user opts in explicitly. The ROADMAP should be updated at design review to reflect this revised gate.

### 1.4 Integration Architecture Decision

CSM-1B is **not yet available** in the `mlx-audio-swift` Swift package. The Mimi audio codec (which CSM depends on) IS available in `mlx-audio-swift`'s `MLXAudioCodecs` module, but the CSM model architecture (Llama backbone + decoder) is not implemented in Swift.

Two viable integration paths exist:

| Approach | Pros | Cons |
|----------|------|------|
| **A: Local Python microservice** (`csm-mlx` or `mlx-audio` server) | Proven API; fast to integrate; `csm-mlx` is maintained | Python dependency; process management; IPC overhead |
| **B: Native Swift implementation** (MLX-Swift + Mimi from mlx-audio-swift) | No Python dep; tighter integration; lower IPC overhead | Major engineering effort; unproven; maintenance burden |

The **design phase** (design.md) will make the final architecture decision. Requirements below are written to be implementation-agnostic — they specify observable behaviour, not the mechanism.

---

## 2. Functional Requirements

### 2.1 Model Lifecycle

**REQ-CSM-01** — WHEN the user enables voice cloning for the first time AND the CSM-1B model is not cached locally THEN the system SHALL present a download sheet showing estimated download size (~2 GB), a progress indicator, and a Cancel button.

**REQ-CSM-02** — WHEN the CSM-1B model download completes THEN the system SHALL cache model files under `~/Library/Application Support/TranslateCall/Models/CSM1B/` and SHALL NOT re-download on subsequent launches.

**REQ-CSM-03** — IF the model download fails (network error, disk full, user cancel) THEN the system SHALL display an error alert with "Retry" and "Cancel" actions, and SHALL NOT enable voice cloning until a successful download occurs.

**REQ-CSM-04** — WHEN the app launches AND voice cloning was previously enabled AND an active voice profile exists THEN the system SHALL load the CSM-1B model in the background without blocking the UI thread or the audio pipeline. During loading, TTS SHALL fall back to the standard engine (Kokoro or AVSpeech).

**REQ-CSM-05** — WHEN the CSM-1B model finishes loading THEN the system SHALL transition seamlessly to voice-cloned synthesis for subsequent utterances. Utterances already in flight SHALL complete with the standard engine.

**REQ-CSM-06** — IF the CSM-1B model fails to load from cache (corrupt files, incompatible version) THEN the system SHALL log the error, set `csmAvailable = false`, fall back to the standard engine, and surface a non-blocking notification suggesting re-download.

**REQ-CSM-07** — WHEN the user disables voice cloning OR removes the active voice profile THEN the system SHALL unload the CSM-1B model from memory and release all associated resources (GPU/ANE allocations, Mimi codec state).

**REQ-CSM-08** — WHEN the user requests a model re-download (via Settings) THEN the system SHALL delete the cached model files and restart the download flow (REQ-CSM-01).

### 2.2 Voice-Conditioned Synthesis

**REQ-CSM-09** — WHEN `speak(text:locale:)` is called on `CSMSpeechService` AND an active voice profile is loaded THEN the system SHALL synthesize audio conditioned on the active profile's reference audio and transcript, producing speech that resembles the user's voice characteristics.

**REQ-CSM-10** — WHEN synthesizing with voice conditioning THEN the system SHALL decrypt the active voice profile on demand via `VoiceProfileStore.load(id:)`, use the `(samples, transcript)` pair as a CSM context Segment, and release the decrypted data from memory after inference completes.

**REQ-CSM-11** — WHEN synthesis completes THEN `CSMSpeechService` SHALL convert the 24 kHz output to the output device's native format, play it through `AVAudioPlayerNode`, and emit `false` on `isSpeakingStream` — matching the `SynthesisService` protocol contract.

**REQ-CSM-12** — WHEN `stopSpeaking()` is called THEN `CSMSpeechService` SHALL cancel any in-progress inference, stop audio playback immediately, flush queued requests, and transition `isSpeakingStream` to `false`.

**REQ-CSM-13** — IF the CSM-1B model is not yet loaded when `speak(text:locale:)` is called THEN `CSMSpeechService` SHALL throw `STSError.engineStartFailed` so the `AudioCoordinator` can fall back to the standard engine for that utterance.

**REQ-CSM-14** — WHEN a synthesis request arrives while a previous utterance is still playing or being inferred THEN `CSMSpeechService` SHALL queue the new request and process it sequentially after the current utterance finishes.

**REQ-CSM-15** — WHEN the input text exceeds 200 characters THEN `CSMSpeechService` SHALL truncate at the last word boundary before 200 characters. (CSM-1B quality degrades on long inputs; shorter than Kokoro's 500-char limit.)

### 2.3 Engine Selection & Fallback

**REQ-CSM-16** — WHEN `TTSEngineSelector` builds the outgoing `SynthesisService` AND voice cloning is enabled AND `csmAvailable == true` AND the target locale is English (`en-*`) THEN it SHALL return a `CSMSpeechService` instance.

**REQ-CSM-17** — WHEN `TTSEngineSelector` builds the outgoing `SynthesisService` AND voice cloning is enabled BUT `csmAvailable == false` (model not loaded/failed) THEN it SHALL fall back to Kokoro (if available) or AVSpeech, and log the fallback reason.

**REQ-CSM-18** — WHEN `TTSEngineSelector` builds the outgoing `SynthesisService` AND the target locale is NOT English THEN it SHALL use the standard engine (Kokoro or AVSpeech) regardless of voice cloning state. Voice cloning is English-only.

**REQ-CSM-19** — WHEN `TTSEngineSelector` builds the incoming `SynthesisService` THEN it SHALL always use the standard engine (Kokoro or AVSpeech). Voice cloning applies only to outgoing speech (the user's translated voice heard by the remote participant).

**REQ-CSM-20** — WHEN voice cloning is enabled THEN `TTSEngineSelector` SHALL expose a published property `voiceCloningActive: Bool` for UI binding (badge, indicator).

### 2.4 Profile Integration

**REQ-CSM-21** — WHEN the active voice profile changes (via `VoiceProfileManager.setActiveProfile`) THEN `CSMSpeechService` SHALL update its conditioning context for subsequent synthesis calls. In-flight synthesis SHALL complete with the previous profile.

**REQ-CSM-22** — WHEN the active voice profile is deleted THEN the system SHALL disable voice cloning, unload the CSM-1B model (REQ-CSM-07), and revert to the standard engine.

**REQ-CSM-23** — WHEN `CSMSpeechService` loads a voice profile for conditioning THEN it SHALL verify `header.sampleRate == 24000` and `header.formatVersion == 1`. IF the format is unsupported THEN it SHALL throw `VoiceProfileError.corruptFile` and fall back to the standard engine.

### 2.5 Inference Lifecycle

**REQ-CSM-24** — WHILE CSM-1B inference is running THEN the system SHALL NOT block the main thread. All inference SHALL execute on a background thread/actor.

**REQ-CSM-25** — WHEN CSM-1B inference begins THEN the system SHALL start a timer. IF inference exceeds 10 seconds THEN the system SHALL cancel it, log a timeout warning, and fall back to the standard engine for that utterance.

**REQ-CSM-26** — WHEN synthesis completes THEN the system SHALL report the inference duration (in milliseconds) to a metrics collector for display in the TTS metrics panel.

---

## 3. Non-Functional Requirements

### 3.1 Performance

**REQ-CSM-NF-01** — CSM-1B model loading SHALL complete within 15 seconds on an M1 MacBook Air (8 GB). Loading status SHALL be observable via an `AsyncStream<ModelState>`.

**REQ-CSM-NF-02** — CSM-1B synthesis latency for a 10-word English sentence SHALL be ≤ 3 seconds on an M1 MacBook Air (8 GB), measured from `speak()` call to first audio sample played.

**REQ-CSM-NF-03** — WHILE CSM-1B is loaded THEN the system's total resident memory increase SHALL be ≤ 2.5 GB over the baseline (no ML models loaded).

**REQ-CSM-NF-04** — WHEN both CSM-1B and Kokoro models would be loaded simultaneously THEN the system SHALL unload Kokoro first, since CSM-1B supersedes it for English TTS. Only one English TTS model SHALL be loaded at a time.

### 3.2 Privacy & Security

**REQ-CSM-NF-05** — ALL CSM-1B inference SHALL execute 100% on-device. No audio, text, or voice profile data SHALL be transmitted to any external service.

**REQ-CSM-NF-06** — WHEN decrypted voice profile samples are loaded for conditioning THEN they SHALL be held in memory only for the duration of inference and SHALL be zeroed/released immediately after.

**REQ-CSM-NF-07** — IF the integration uses a local Python subprocess THEN the subprocess SHALL bind only to `127.0.0.1` (localhost) and SHALL NOT accept connections from other hosts.

### 3.3 Reliability

**REQ-CSM-NF-08** — IF CSM-1B crashes or produces an exception during inference THEN `CSMSpeechService` SHALL catch the error, log it, mark `csmAvailable = false`, and fall back to the standard engine. The translation pipeline SHALL NOT be interrupted.

**REQ-CSM-NF-09** — WHEN the app is backgrounded or the display sleeps THEN the system SHALL NOT unload the CSM-1B model proactively. The model SHALL remain resident until explicitly disabled or the app quits.

**REQ-CSM-NF-10** — IF a Python subprocess is used THEN the system SHALL monitor its health via periodic heartbeat. IF the subprocess becomes unresponsive for > 5 seconds THEN the system SHALL restart it automatically (up to 3 retries) before falling back to the standard engine.

### 3.4 Testability

**REQ-CSM-NF-11** — `CSMSpeechService` SHALL accept an injectable inference backend (protocol/closure) so unit tests can run without loading the real CSM-1B model.

**REQ-CSM-NF-12** — Model download, loading, and inference state transitions SHALL be testable via published properties or `AsyncStream` without requiring network access or GPU hardware.

---

## 4. Acceptance Criteria

| ID | Criterion | Validation Method |
|----|-----------|-------------------|
| AC-01 | CSM-1B model downloads and caches successfully | Automated test: mock download + file existence check |
| AC-02 | Voice-cloned synthesis produces audio using active profile | Automated test: mock inference returns samples; verify `isSpeakingStream` lifecycle |
| AC-03 | Fallback to Kokoro/AVSpeech when CSM unavailable | Automated test: `csmAvailable = false` → `TTSEngineSelector` returns standard engine |
| AC-04 | Fallback for non-English locales | Automated test: locale `es-ES` → standard engine even with cloning enabled |
| AC-05 | Profile decryption on demand + cleanup after inference | Automated test: verify `VoiceProfileStore.load` called; samples released post-inference |
| AC-06 | Model unloaded when cloning disabled | Automated test: disable cloning → model state transitions to `.idle` |
| AC-07 | Inference timeout at 10 seconds | Automated test: mock slow inference → verify cancellation + fallback |
| AC-08 | Text truncation at 200 characters | Automated test: 300-char input → verify truncated at last word boundary ≤ 200 |
| AC-09 | Memory: Kokoro unloaded when CSM loaded | Automated test: CSM load → verify Kokoro model state is `.idle` |
| AC-10 | `CSMSpeechService` conforms to `SynthesisService` protocol | Compile-time check |
| AC-11 | Metrics reported to `TTSMetricsCollector` | Automated test: verify inference duration metric emitted |
| AC-12 | Total pipeline latency ≤ 3 s (10-word sentence, M1) | Manual benchmark on hardware |

---

## 5. Open Questions (for Design Phase)

| ID | Question | Impact |
|----|----------|--------|
| OQ-1 | **Python bridge vs native Swift?** csm-mlx (Python) is proven but adds a process dependency. Native Swift using MLX-Swift + Mimi codec is cleaner but requires implementing the Llama backbone + decoder in Swift. Which approach? | Architecture, complexity, maintenance |
| OQ-2 | **Quantisation**: Should we use 4-bit quantised weights to reduce memory from ~2 GB to ~1 GB? What quality trade-off? | Memory, quality |
| OQ-3 | **Streaming inference**: csm-mlx supports streaming (first chunk in 1–2 s). Should F7.2 implement streaming playback or batch-then-play? Streaming reduces perceived latency but adds complexity. | Latency, complexity |
| OQ-4 | **Mimi codec caching**: CSM re-encodes the reference audio through Mimi on every inference call. Can we cache the encoded tokens for the active profile to save ~200–500 ms per call? | Latency optimisation |
| OQ-5 | **Model version pinning**: How do we handle CSM-1B model updates on HuggingFace? Pin to a specific commit hash, or allow updates with validation? | Reliability, reproducibility |
| OQ-6 | **Concurrent GPU/ANE access**: CSM-1B uses MLX (GPU). Parakeet STT also uses MLX. Can they coexist without contention, or do we need to serialise access? | Performance, stability |

---

## 6. Dependency Map

```
F7.1 (Voice Profile Training) ✅
  │
  ├── VoiceProfile (24 kHz Float32 + transcript) ──▶ CSM Segment input
  ├── VoiceProfileStore (encrypted .vpf files) ──▶ On-demand decryption
  └── VoiceProfileManager (active profile) ──▶ Profile change notifications
          │
          ▼
F7.2 (CSM-1B Integration) ◀── THIS FEATURE
  │
  ├── CSMSpeechService ──▶ SynthesisService protocol
  ├── CSMModelManager ──▶ Download + load + state machine
  └── TTSEngineSelector ──▶ Engine routing (CSM > Kokoro > AVSpeech)
          │
          ▼
F7.3 (Voice Cloning UX) ○
  │
  ├── A/B toggle UI
  ├── Voice similarity preview
  └── Per-language tuning
```

---

## 7. Glossary

| Term | Definition |
|------|------------|
| **CSM-1B** | Conversational Speech Model (1B parameters) by Sesame AI Labs. Generates speech from text + audio context. |
| **Mimi** | Audio codec used internally by CSM-1B to encode reference audio into RVQ (Residual Vector Quantisation) tokens. |
| **Segment** | CSM input unit: `(text, speaker_id, audio)` — a paired recording and its transcript used for voice conditioning. |
| **Voice conditioning** | The process of providing reference audio so CSM-1B generates speech mimicking the speaker's voice characteristics. |
| **csm-mlx** | Python port of CSM-1B optimised for Apple Silicon via the MLX framework (by Senstella). |
| **mlx-audio-swift** | Swift package for ML audio tasks (by Blaizzy). Contains Mimi codec but NOT CSM model architecture. |

---

*This document defines **what** the system must do. The **how** (architecture, data flow, implementation) is covered in `design.md` after this document is approved.*
