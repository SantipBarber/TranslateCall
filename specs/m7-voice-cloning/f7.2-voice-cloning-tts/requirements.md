# F7.2 — Voice Cloning TTS (Qwen3-TTS): Requirements

> **Feature**: F7.2 — Voice Cloning TTS Integration
> **Milestone**: M7 — Voice Cloning
> **Status**: DRAFT
> **Author**: SDD Process
> **Date**: 2026-03-14
> **Depends on**: F7.1 (Voice Profile Training — COMPLETED)
> **Supersedes**: F7.2-CSM-1B (archived — Python dependency eliminated)

---

## 1. Overview

Integrate **Qwen3-TTS 0.6B-Base** via the `mlx-audio-swift` Swift package as a native voice-cloning TTS engine. When an active voice profile exists and the user enables voice cloning, translated speech is synthesized in the user's own voice instead of a generic TTS voice. Qwen3-TTS replaces Kokoro/AVSpeech in the outgoing pipeline while the profile is active; the incoming pipeline continues using the standard TTS engine.

### 1.1 Why Qwen3-TTS (Pivot from CSM-1B)

The original F7.2 spec used CSM-1B via a Python microservice (`csm-mlx`). During implementation (2026-03-14), we discovered:

| Factor | CSM-1B | Qwen3-TTS 0.6B-Base |
|--------|--------|---------------------|
| Swift native | No (Python required) | **Yes** (`mlx-audio-swift`) |
| Languages | English only | **10 languages** (EN, ES, FR, DE, IT, PT, RU, ZH, JA, KO) |
| Speaker similarity | 0.65 (PoC3) | **0.89** (Seed-TTS-Eval) |
| Min reference audio | ~10 seconds | **3 seconds** |
| Cross-lingual cloning | No | **Yes** (clone EN voice → speak ES) |
| Dependencies | Python 3.10+, venv, subprocess, HTTP | **Zero** — pure Swift SPM |
| Peak memory (4-bit) | ~1.5 GB | ~2 GB |
| RTF (real-time factor) | ~2-6s per utterance | **~0.7** (faster than real-time) |

Qwen3-TTS is superior in every dimension. The cross-lingual cloning is transformative for a translation app: the user's cloned voice can speak the target language.

### 1.2 Scope

- **In scope**: Qwen3-TTS model download and lifecycle management; a new `SynthesisService`-conforming actor (`QwenCloneSpeechService`); voice conditioning from the active `VoiceProfile` (F7.1: 24 kHz Float32 PCM + transcript); integration into `TTSEngineSelector` as a third engine tier (Voice Clone > Kokoro > AVSpeech); fallback when model unavailable; inference latency monitoring; memory management (load/unload on demand).
- **Out of scope**: Voice similarity scoring or quality validation (F7.3); A/B toggle UI and preview (F7.3); per-language voice profile tuning (F7.3); multi-speaker profiles; streaming/chunked synthesis (future optimisation); fine-tuning; voice profile recording or management (F7.1).

### 1.3 Key Constraints

| Constraint | Value | Source |
|------------|-------|--------|
| Model | Qwen3-TTS-12Hz-0.6B-Base | mlx-community HuggingFace |
| Quantization | 4-bit (default) or 8-bit | mlx-community model variants |
| Swift package | `mlx-audio-swift` (`MLXAudioTTS` product) | github.com/Blaizzy/mlx-audio-swift |
| Output sample rate | 24 kHz mono | Qwen3-TTS spec |
| Reference audio | 24 kHz mono Float32 PCM + UTF-8 transcript | F7.1 `VoiceProfile` format (exact match) |
| Min reference duration | 3 seconds | Qwen3-TTS documentation |
| Language support | 10 languages (EN, ES, FR, DE, IT, PT, RU, ZH, JA, KO) | Qwen3-TTS training data |
| Apple Silicon required | M1 or later | MLX runtime requirement |
| Model size (disk, 4-bit) | ~1.7 GB | HuggingFace model card |
| Peak RAM (4-bit) | ~2 GB | Community benchmarks |
| Latency target | ≤ 1.5 s additional over Kokoro (≤ 3 s total pipeline) | RTF ~0.7 suggests achievable |
| Minimum macOS | 15.0 | Project deployment target (package supports 14.0+) |

### 1.4 Integration Architecture

Pure Swift, no Python, no subprocess, no HTTP:

```
VoiceProfile (F7.1)
  │ 24 kHz Float32 + transcript
  ▼
QwenCloneSpeechService (actor, SynthesisService)
  │ loads Qwen3-TTS via mlx-audio-swift
  │ calls generateVoiceClone(text:referenceAudio:referenceText:)
  ▼
MLXArray [Float] 24 kHz mono
  │ AVAudioConverter SRC → device sample rate
  ▼
AVAudioPlayerNode → Output device / BlackHole
```

Dependencies: `MLXAudioTTS` (from `mlx-audio-swift` SPM package). Model files auto-download from HuggingFace Hub on first use, cached in `~/.cache/huggingface/hub/`.

---

## 2. Functional Requirements

### 2.1 Model Lifecycle

**REQ-VC-01** — WHEN the user enables voice cloning for the first time AND the Qwen3-TTS model is not cached locally THEN the system SHALL present a download sheet showing estimated download size (~1.7 GB for 4-bit), a progress indicator, and a Cancel button.

**REQ-VC-02** — WHEN the model download completes THEN the system SHALL cache model files via HuggingFace Hub (`~/.cache/huggingface/hub/`) and SHALL NOT re-download on subsequent launches.

**REQ-VC-03** — IF the model download fails (network error, disk full, user cancel) THEN the system SHALL display an error alert with "Retry" and "Cancel" actions, and SHALL NOT enable voice cloning until a successful download occurs.

**REQ-VC-04** — WHEN the app launches AND voice cloning was previously enabled AND an active voice profile exists THEN the system SHALL load the Qwen3-TTS model in the background without blocking the UI or audio pipeline. During loading, TTS SHALL fall back to the standard engine (Kokoro or AVSpeech).

**REQ-VC-05** — WHEN the model finishes loading THEN the system SHALL transition seamlessly to voice-cloned synthesis for subsequent utterances. Utterances already in flight SHALL complete with the standard engine.

**REQ-VC-06** — IF the model fails to load (corrupt files, incompatible version) THEN the system SHALL log the error, set `qwenCloneAvailable = false`, fall back to the standard engine, and surface a non-blocking notification suggesting re-download.

**REQ-VC-07** — WHEN the user disables voice cloning OR removes the active voice profile THEN the system SHALL unload the model from memory and release all associated resources (GPU/Metal allocations).

**REQ-VC-08** — WHEN the user requests a model re-download (via Settings) THEN the system SHALL delete the cached model files and restart the download flow (REQ-VC-01).

### 2.2 Voice-Conditioned Synthesis

**REQ-VC-09** — WHEN `speak(text:locale:)` is called on `QwenCloneSpeechService` AND an active voice profile is loaded THEN the system SHALL synthesize audio conditioned on the profile's reference audio and transcript, producing speech that resembles the user's voice.

**REQ-VC-10** — WHEN synthesizing with voice conditioning THEN the system SHALL decrypt the active voice profile on demand via `VoiceProfileStore.load(id:)`, use the `(samples, transcript)` pair as reference audio, and release the decrypted data from memory after inference completes.

**REQ-VC-11** — WHEN synthesis completes THEN `QwenCloneSpeechService` SHALL convert the 24 kHz output to the output device's native format, play it through `AVAudioPlayerNode`, and emit `false` on `isSpeakingStream` — matching the `SynthesisService` protocol contract.

**REQ-VC-12** — WHEN `stopSpeaking()` is called THEN `QwenCloneSpeechService` SHALL cancel any in-progress inference, stop audio playback immediately, flush queued requests, and transition `isSpeakingStream` to `false`.

**REQ-VC-13** — IF the model is not yet loaded when `speak(text:locale:)` is called THEN `QwenCloneSpeechService` SHALL log the error and fall back gracefully. The translation pipeline SHALL NOT be interrupted.

**REQ-VC-14** — WHEN a synthesis request arrives while a previous utterance is still playing or being inferred THEN `QwenCloneSpeechService` SHALL queue the new request and process it sequentially.

**REQ-VC-15** — WHEN the input text exceeds 200 characters THEN `QwenCloneSpeechService` SHALL truncate at the last word boundary before 200 characters.

### 2.3 Cross-Lingual Voice Cloning

**REQ-VC-16** — WHEN voice cloning is active AND the target locale is one of the 10 supported languages THEN `QwenCloneSpeechService` SHALL synthesize in the target language while preserving the user's voice characteristics from the English reference audio.

**REQ-VC-17** — WHEN voice cloning is active AND the target locale is NOT one of the 10 supported languages THEN `TTSEngineSelector` SHALL fall back to the standard engine (Kokoro or AVSpeech).

### 2.4 Engine Selection & Fallback

**REQ-VC-18** — WHEN `TTSEngineSelector` builds the outgoing `SynthesisService` AND voice cloning is enabled AND `qwenCloneAvailable == true` AND the target locale is supported THEN it SHALL return a `QwenCloneSpeechService` instance.

**REQ-VC-19** — WHEN `TTSEngineSelector` builds the outgoing `SynthesisService` AND voice cloning is enabled BUT `qwenCloneAvailable == false` THEN it SHALL fall back to Kokoro (if available) or AVSpeech.

**REQ-VC-20** — WHEN `TTSEngineSelector` builds the incoming `SynthesisService` THEN it SHALL always use the standard engine. Voice cloning applies only to outgoing speech.

**REQ-VC-21** — WHEN voice cloning is enabled THEN `TTSEngineSelector` SHALL expose a published property `voiceCloningActive: Bool` for UI binding.

### 2.5 Profile Integration

**REQ-VC-22** — WHEN the active voice profile changes THEN `QwenCloneSpeechService` SHALL update its conditioning context for subsequent calls. In-flight synthesis SHALL complete with the previous profile.

**REQ-VC-23** — WHEN the active voice profile is deleted THEN the system SHALL disable voice cloning, unload the model (REQ-VC-07), and revert to the standard engine.

**REQ-VC-24** — WHEN `QwenCloneSpeechService` loads a voice profile for conditioning THEN it SHALL verify `header.sampleRate == 24000` and `header.formatVersion == 1`. IF unsupported THEN throw `VoiceProfileError.corruptFile`.

### 2.6 Inference Lifecycle

**REQ-VC-25** — WHILE inference is running THEN the system SHALL NOT block the main thread. All inference SHALL execute on a background actor.

**REQ-VC-26** — WHEN inference begins THEN the system SHALL start a timer. IF inference exceeds 10 seconds THEN cancel, log a timeout warning, and fall back for that utterance.

**REQ-VC-27** — WHEN synthesis completes THEN the system SHALL report inference duration (ms) to `TTSMetricsCollector` for display in the TTS metrics panel.

---

## 3. Non-Functional Requirements

### 3.1 Performance

**REQ-VC-NF-01** — Model loading SHALL complete within 15 seconds on an M1 MacBook Air (8 GB). Loading status SHALL be observable via `AsyncStream<ModelState>`.

**REQ-VC-NF-02** — Synthesis latency for a 10-word sentence SHALL be ≤ 3 seconds on M1 (8 GB), measured from `speak()` to first audio sample played.

**REQ-VC-NF-03** — While model is loaded, total resident memory increase SHALL be ≤ 2.5 GB over baseline (no ML models).

**REQ-VC-NF-04** — When voice cloning loads Qwen3-TTS, the system SHALL unload Kokoro first (only one MLX TTS model at a time).

### 3.2 Privacy & Security

**REQ-VC-NF-05** — ALL inference SHALL execute 100% on-device. No audio, text, or voice profile data SHALL be transmitted externally. Model download from HuggingFace is the only network operation.

**REQ-VC-NF-06** — Decrypted voice profile samples SHALL be held in memory only during inference and released immediately after.

### 3.3 Reliability

**REQ-VC-NF-07** — IF the model crashes or raises an exception during inference THEN `QwenCloneSpeechService` SHALL catch, log, mark `qwenCloneAvailable = false`, and fall back. The pipeline SHALL NOT be interrupted.

**REQ-VC-NF-08** — WHEN the app is backgrounded or display sleeps THEN the model SHALL remain resident until explicitly disabled or the app quits.

### 3.4 Testability

**REQ-VC-NF-09** — `QwenCloneSpeechService` SHALL accept an injectable inference backend (protocol) so unit tests run without loading the real model.

**REQ-VC-NF-10** — Model download, loading, and inference state transitions SHALL be testable via published properties or `AsyncStream` without network access or GPU.

---

## 4. Acceptance Criteria

| ID | Criterion | Validation |
|----|-----------|------------|
| AC-01 | Model downloads and caches via HuggingFace Hub | Manual: first launch downloads ~1.7 GB, second launch skips |
| AC-02 | Voice-cloned synthesis produces audio using active profile | Automated test: mock inference returns samples; verify `isSpeakingStream` lifecycle |
| AC-03 | Fallback when model unavailable | Automated test: `qwenCloneAvailable = false` → standard engine |
| AC-04 | Cross-lingual cloning (EN profile → ES speech) | Manual: record EN profile, speak ES → cloned voice in Spanish |
| AC-05 | Fallback for unsupported locales | Automated test: unsupported locale → standard engine |
| AC-06 | Profile decryption on demand + cleanup | Automated test: verify store.load called; samples released post-inference |
| AC-07 | Model unloaded when cloning disabled | Automated test: disable → model state `.idle` |
| AC-08 | Inference timeout at 10 seconds | Automated test: mock slow inference → cancellation + fallback |
| AC-09 | Text truncation at 200 characters | Automated test: 300-char input → truncated ≤ 200 |
| AC-10 | Kokoro unloaded when voice clone loaded | Automated test: voice clone load → Kokoro `.idle` |
| AC-11 | `QwenCloneSpeechService` conforms to `SynthesisService` | Compile-time check |
| AC-12 | Metrics reported to `TTSMetricsCollector` | Automated test: verify metric emitted |
| AC-13 | Total pipeline latency ≤ 3 s (10-word, M1) | Manual benchmark |
| AC-14 | No Python dependency — pure Swift build | CI: `xcodebuild` succeeds without Python |

---

## 5. Open Questions (for Design Phase)

| ID | Question | Impact |
|----|----------|--------|
| OQ-1 | **Quantization**: 4-bit (~1.7 GB, ~2 GB RAM) vs 8-bit (~2 GB, ~2.5 GB RAM). Quality difference for voice cloning? | Memory, quality |
| OQ-2 | **Streaming**: `generateStream()` provides event-based streaming but audio arrives at end. Worth using for progress UI, or batch-only? | UX, complexity |
| OQ-3 | **Concurrent MLX models**: Qwen3-TTS + Parakeet STT both use MLX/Metal. Can they coexist? Serialize GPU access? | Performance, stability |
| OQ-4 | **Model unload**: No explicit `unload()` in mlx-audio-swift. Does setting model to `nil` promptly release GPU memory? | Memory management |
| OQ-5 | **HuggingFace cache location**: Default is `~/.cache/huggingface/hub/`. Should we use a custom app-specific path? | Disk management, cleanup |
| OQ-6 | **Voice profile resampling**: F7.1 profiles are 24 kHz. Qwen3-TTS accepts any sample rate (resamples internally). Pass raw or let model resample? | Simplicity vs control |

---

## 6. Dependency Map

```
F7.1 (Voice Profile Training) ✅
  │
  ├── VoiceProfile (24 kHz Float32 + transcript) ──▶ Reference audio input
  ├── VoiceProfileStore (encrypted .vpf files) ──▶ On-demand decryption
  └── VoiceProfileManager (active profile) ──▶ Profile change notifications
          │
          ▼
F7.2 (Voice Cloning TTS — Qwen3-TTS) ◀── THIS FEATURE
  │
  ├── QwenCloneSpeechService ──▶ SynthesisService protocol
  ├── QwenCloneModelManager ──▶ Download + load + state machine
  ├── TTSEngine.voiceClone ──▶ Third engine case
  └── TTSEngineSelector ──▶ Engine routing (VoiceClone > Kokoro > AVSpeech)
          │
          ▼
F7.3 (Voice Cloning UX) ○
  │
  ├── A/B toggle UI
  ├── Voice similarity preview
  └── Per-language tuning
```

---

## 7. Migration from CSM-1B Implementation

The CSM-1B implementation (T0-T8) produced these files that will be **replaced**:

| CSM-1B File | Action | Qwen3-TTS Replacement |
|-------------|--------|----------------------|
| `CSMConfiguration.swift` | Delete | `QwenCloneConfiguration.swift` |
| `CSMInferring.swift` | Delete | `QwenCloneInferring.swift` (protocol) |
| `CSMClient.swift` | Delete | N/A (no HTTP client needed) |
| `CSMProcessManager.swift` | Delete | N/A (no subprocess needed) |
| `CSMModelManager.swift` | Replace | `QwenCloneModelManager.swift` |
| `CSMSpeechService.swift` | Replace | `QwenCloneSpeechService.swift` |
| `csm_server.py` | Delete | N/A |
| `setup_csm_env.sh` | Delete | N/A |
| All `CSM*Tests.swift` | Replace | `QwenClone*Tests.swift` |

Files that remain with modifications:
- `TTSEngine.swift` — rename `.csm` → `.voiceClone`
- `TTSEngineSelector.swift` — update factory, remove CSM imports
- `ContentView.swift` — update download sheet text
- `AudioViewModel.swift` — minimal changes (same wiring pattern)

---

## 8. Glossary

| Term | Definition |
|------|------------|
| **Qwen3-TTS** | Text-to-speech model by Alibaba/Qwen (0.6B and 1.7B variants). Supports 10 languages and voice cloning from 3-second reference audio. |
| **mlx-audio-swift** | Swift package for ML audio tasks (by Blaizzy/Prince Canuma). Provides `MLXAudioTTS` product with native Qwen3-TTS support. |
| **Voice cloning** | Synthesizing speech that mimics a specific person's voice characteristics using short reference audio. |
| **Cross-lingual cloning** | Cloning a voice from one language (e.g., English) and synthesizing in another (e.g., Spanish). |
| **Base model** | The Qwen3-TTS variant that supports voice cloning (vs. CustomVoice/VoiceDesign variants). |
| **HuggingFace Hub** | Model hosting platform. mlx-audio-swift auto-downloads models from `mlx-community/` repos. |

---

*This document defines **what** the system must do. The **how** (architecture, data flow, implementation) is covered in `design.md` after this document is approved.*
