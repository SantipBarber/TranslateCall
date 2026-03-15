# F7.2 — Voice Cloning TTS (Qwen3-TTS): Design

> **Feature**: F7.2 — Voice Cloning TTS Integration
> **Milestone**: M7 — Voice Cloning
> **Status**: DRAFT
> **Date**: 2026-03-14
> **Depends on**: requirements.md (this document)
> **Supersedes**: F7.2-CSM-1B design (archived)

---

## 1. Architecture Overview

Pure Swift integration — no Python, no subprocess, no HTTP. The `mlx-audio-swift` SPM package provides native Qwen3-TTS inference via MLX/Metal on Apple Silicon.

```
┌─────────────────────────────────────────────────────────────┐
│  TTSEngineSelector                                          │
│  ┌─────────┐  ┌────────┐  ┌──────────────────────┐         │
│  │AVSpeech │  │ Kokoro │  │ QwenCloneSpeechService│         │
│  │ Service │  │ Service│  │  (SynthesisService)   │         │
│  └─────────┘  └────────┘  └──────────┬───────────┘         │
│                                      │                      │
│                            ┌─────────▼──────────┐          │
│                            │QwenCloneModelManager│          │
│                            │  (actor singleton)  │          │
│                            └─────────┬──────────┘          │
│                                      │                      │
│                            ┌─────────▼──────────┐          │
│                            │  mlx-audio-swift    │          │
│                            │  (MLXAudioTTS)      │          │
│                            │  SpeechGeneration   │          │
│                            │  Model protocol     │          │
│                            └────────────────────┘          │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 Data Flow (Voice-Cloned Utterance)

```
1. AudioCoordinator receives translated text
2. TTSEngineSelector.makeOutgoingService() → QwenCloneSpeechService
3. QwenCloneSpeechService.speak(text:locale:)
   a. Decrypt active VoiceProfile (24 kHz Float32 + transcript)
   b. Convert profile samples → MLXArray
   c. Call model.generate(text:refAudio:refText:language:params)
   d. Convert MLXArray output → [Float]
   e. makePCMBuffer: 24 kHz → device sample rate (AVAudioConverter)
   f. AVAudioPlayerNode.scheduleBuffer → play
4. isSpeakingStream emits false when buffer completes
```

---

## 2. Package Integration

### 2.1 SPM Dependency

Add to `TranslateCall.xcodeproj` → Package Dependencies:

```
URL: https://github.com/Blaizzy/mlx-audio-swift.git
Version: from 0.30.6
```

Link **`MLXAudioTTS`** and **`MLXAudioCore`** products to the `TranslateCall` target.

### 2.2 Model Selection

| Variant | Disk | RAM | Quality | Recommended |
|---------|------|-----|---------|-------------|
| `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit` | 1.71 GB | ~2 GB | Good | Budget RAM |
| `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit` | 1.99 GB | ~2.5 GB | **Best** | **Default** |
| `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16` | 2.52 GB | ~3 GB | Reference | Dev only |

**Default**: 8-bit (best quality/memory trade-off for 16 GB+ machines).
Configurable via `QwenCloneConfiguration.modelRepo`.

---

## 3. Component Design

### 3.1 QwenCloneInferring (Protocol)

```swift
// Core/VoiceCloning/QwenCloneInferring.swift

/// Abstracts Qwen3-TTS inference for testability.
/// Production: wraps mlx-audio-swift's SpeechGenerationModel.
/// Tests: MockQwenCloneInferrer returns stub samples.
protocol QwenCloneInferring: Actor {
    func synthesize(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) async throws -> [Float]

    var sampleRate: Int { get }
}
```

### 3.2 QwenCloneClient (Production Inferrer)

```swift
// Core/VoiceCloning/QwenCloneClient.swift

import MLXAudioTTS
import MLXAudioCore
import MLX

/// Production implementation wrapping mlx-audio-swift.
actor QwenCloneClient: QwenCloneInferring {
    private let model: any SpeechGenerationModel

    nonisolated let sampleRate: Int

    init(model: any SpeechGenerationModel) {
        self.model = model
        self.sampleRate = model.sampleRate  // 24000
    }

    func synthesize(
        text: String,
        referenceAudio: [Float],
        referenceTranscript: String,
        language: String
    ) async throws -> [Float] {
        let refAudio = MLXArray(referenceAudio)

        let params = GenerateParameters(
            maxTokens: 2048,
            temperature: 0.7,
            topP: 0.95,
            repetitionPenalty: 1.5
        )

        let output = try await model.generate(
            text: text,
            voice: nil,
            refAudio: refAudio,
            refText: referenceTranscript,
            language: language,
            generationParameters: params
        )

        return output.asArray(Float.self)
    }
}
```

### 3.3 QwenCloneConfiguration

```swift
// Core/VoiceCloning/QwenCloneConfiguration.swift

/// Configuration for Qwen3-TTS voice cloning.
nonisolated struct QwenCloneConfiguration: Sendable {
    var modelRepo: String = "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
    var maxTokens: Int = 2048
    var temperature: Float = 0.7
    var topP: Float = 0.95
    var repetitionPenalty: Float = 1.5
    var inferenceTimeoutSeconds: Int = 10
    var textTruncationLimit: Int = 200

    nonisolated(unsafe) static let `default` = QwenCloneConfiguration()

    static let voiceCloningEnabledKey = "tlk.voiceCloning.enabled"

    /// Maps Locale → Qwen3-TTS language string.
    static func language(for locale: Locale) -> String? {
        let code = locale.language.languageCode?.identifier ?? ""
        switch code {
        case "en": return "english"
        case "es": return "spanish"
        case "fr": return "french"
        case "de": return "german"
        case "it": return "italian"
        case "pt": return "portuguese"
        case "ru": return "russian"
        case "zh": return "chinese"
        case "ja": return "japanese"
        case "ko": return "korean"
        default:   return nil
        }
    }

    /// Returns true if the locale is supported for voice cloning.
    static func supportsLocale(_ locale: Locale) -> Bool {
        language(for: locale) != nil
    }
}
```

### 3.4 QwenCloneModelManager (Actor Singleton)

```swift
// Core/VoiceCloning/QwenCloneModelManager.swift

/// Manages Qwen3-TTS model lifecycle: download → load → ready.
/// Mirrors KokoroModelManager pattern.
actor QwenCloneModelManager {
    enum ModelState: Sendable {
        case idle
        case downloading
        case loading
        case ready
        case failed(String)
    }

    static let shared = QwenCloneModelManager()

    private(set) var state: ModelState = .idle
    private var loadTask: Task<Void, Error>?
    private var model: (any SpeechGenerationModel)?
    private var inferrer: QwenCloneClient?

    nonisolated let stateStream: AsyncStream<ModelState>
    private let stateContinuation: AsyncStream<ModelState>.Continuation

    private let config: QwenCloneConfiguration

    init(config: QwenCloneConfiguration = .default) {
        self.config = config
        var cont: AsyncStream<ModelState>.Continuation!
        stateStream = AsyncStream { cont = $0 }
        stateContinuation = cont
    }

    func ensureReady() async throws {
        switch state {
        case .ready: return
        case .downloading, .loading:
            if let task = loadTask { try await task.value; return }
            try await startSetup()
        case .idle, .failed:
            try await startSetup()
        }
    }

    func getInferrer() throws -> QwenCloneClient {
        guard case .ready = state, let inferrer else {
            throw QwenCloneError.modelNotReady
        }
        return inferrer
    }

    nonisolated func getInferrerUnchecked() -> QwenCloneClient? {
        // For factory usage when caller already checked availability
        nil // Requires async access — design note below
    }

    func unload() {
        loadTask?.cancel()
        loadTask = nil
        model = nil
        inferrer = nil
        transition(to: .idle)
    }

    func isModelCached() -> Bool {
        // HuggingFace Hub caches to ~/.cache/huggingface/hub/
        // Check for model directory existence
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent("models--\(config.modelRepo.replacingOccurrences(of: "/", with: "--"))")
        return FileManager.default.fileExists(atPath: cacheDir.path)
    }

    // MARK: - Private

    private func startSetup() async throws {
        let task = Task<Void, Error> {
            transition(to: .downloading)

            // TTS.loadModel handles download + caching via HuggingFace Hub
            let loadedModel = try await TTS.loadModel(
                modelRepo: config.modelRepo
            )

            transition(to: .loading)

            let client = QwenCloneClient(model: loadedModel)
            self.model = loadedModel
            self.inferrer = client

            transition(to: .ready)
        }
        loadTask = task
        do {
            try await task.value
        } catch {
            transition(to: .failed(error.localizedDescription))
            throw error
        }
    }

    private func transition(to newState: ModelState) {
        state = newState
        stateContinuation.yield(newState)
    }
}
```

**Design note**: Unlike CSM-1B, there is no subprocess to manage. `TTS.loadModel()` handles HuggingFace download + caching automatically. The transition from `.downloading` to `.loading` to `.ready` happens within a single async call.

### 3.5 QwenCloneSpeechService (SynthesisService Actor)

Same structural pattern as `CSMSpeechService` and `KokoroSpeechService`:

```swift
// Core/VoiceCloning/QwenCloneSpeechService.swift

/// Actor-based TTS service using Qwen3-TTS for voice-cloned synthesis.
/// Audio pipeline: Qwen3-TTS [Float] 24kHz → AVAudioConverter SRC → AVAudioPlayerNode.
actor QwenCloneSpeechService: SynthesisService {
    // Same audio engine setup as KokoroSpeechService/CSMSpeechService
    // (AVAudioEngine + PlayerNode + MixerNode)

    private let inferrer: any QwenCloneInferring
    private let profileStore: any VoiceProfileStoring
    private let activeProfileId: UUID
    private let config: QwenCloneConfiguration

    // SynthesisService protocol: isSpeakingStream, speak(), stopSpeaking(), deactivate()
    // Queue management: pendingTexts array, processNext() loop
    // Timeout: withThrowingTaskGroup (same 10s pattern)
    // Metrics: recordMetrics(engine: .voiceClone, ...)

    // Key difference from CSM: language parameter
    private func processNext() async {
        // ...
        let language = QwenCloneConfiguration.language(for: locale) ?? "english"

        let audio = try await inferWithTimeout(
            text: inputText,
            referenceAudio: samples,
            referenceTranscript: transcript,
            language: language
        )
        // ...
    }
}
```

### 3.6 TTSEngine Updates

```swift
// Core/TTS/TTSEngine.swift

enum TTSEngine: String, Codable, Sendable, CaseIterable {
    case avSpeech
    case kokoro
    case voiceClone  // renamed from .csm

    var displayName: String {
        switch self {
        case .avSpeech:    return "AVSpeech"
        case .kokoro:      return "Kokoro"
        case .voiceClone:  return "Voice Clone"
        }
    }

    func supports(locale: Locale) -> Bool {
        switch self {
        case .avSpeech:    return true
        case .kokoro:      return locale.isEnglish
        case .voiceClone:  return QwenCloneConfiguration.supportsLocale(locale)
        }
    }
}
```

### 3.7 TTSEngineSelector Updates

Key changes from CSM-1B version:

1. Replace `CSMModelManager` references → `QwenCloneModelManager`
2. Replace `csmAvailable` → `qwenCloneAvailable`
3. Replace `isCSMDownloading` → `isVoiceCloneDownloading`
4. Update factory: no more `getClientUnchecked()` — use async `getInferrer()`
5. **Language routing**: Voice Clone now supports 10 languages (not just English)

```swift
// Key change in makeOutgoingService:
func makeOutgoingService(for locale: Locale, deviceID: AudioDeviceID?) throws -> any SynthesisService {
    // Priority 1: Voice Clone (10 supported languages)
    if voiceCloningActive,
       QwenCloneConfiguration.supportsLocale(locale),
       let profileId = activeVoiceProfileId,
       let store = profileStore {
        return try voiceCloneFactory(deviceID, profileId, store)
    }

    // Priority 2: Kokoro (English only)
    if preferredEngine == .kokoro, kokoroAvailable, locale.isEnglish { ... }

    // Priority 3: AVSpeech (all languages)
    return try avSpeechFactory(deviceID)
}
```

---

## 4. UI Changes

Minimal — same structure as CSM-1B implementation:

### 4.1 ContentView

- Download sheet text: "Setting Up Voice Cloning" → "Downloading Voice Clone Model (~2 GB)"
- Badge: "Cloning ON" (unchanged)
- Property names: `isCSMDownloading` → `isVoiceCloneDownloading`

### 4.2 LanguagePairView

- Same picker logic (selecting "Voice Clone" calls `enableVoiceCloning()`)
- No changes needed beyond the engine rename

### 4.3 TTSMetricsView

- Column header: show "Voice Clone" for `.voiceClone` engine metrics

---

## 5. Memory Management

### 5.1 Model Load/Unload Strategy

```
User enables Voice Clone → enableVoiceCloning()
  → if Kokoro loaded: unload Kokoro first (NF-04)
  → QwenCloneModelManager.ensureReady()
  → TTS.loadModel() downloads + loads model
  → qwenCloneAvailable = true

User disables Voice Clone → disableVoiceCloning()
  → QwenCloneModelManager.unload()
  → model = nil (ARC releases)
  → MLX.GPU.set(cacheLimit: 0) // flush Metal cache
  → qwenCloneAvailable = false
```

### 5.2 MLX Memory Tips

From community experience (Speaklone app):
- Set `MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)` (512 MB) to limit Metal cache
- Convert `MLXArray` to `[Float]` eagerly to break computation graph
- Call `MLX.GPU.clearCache()` between generations if memory pressure detected

---

## 6. Error Handling

| Error | Source | Recovery |
|-------|--------|----------|
| Network error during download | HuggingFace Hub | Retry dialog; fall back to standard TTS |
| Model load failure | mlx-audio-swift | Log, set `qwenCloneAvailable = false`, fall back |
| Inference timeout (>10s) | Task group timer | Cancel, log, fall back for that utterance |
| Inference exception | MLX runtime | Catch, log, set unavailable, fall back |
| Profile decrypt failure | VoiceProfileStore | Log, skip utterance, continue queue |
| Unsupported locale | QwenCloneConfiguration | Route to Kokoro/AVSpeech (not an error) |

---

## 7. Testing Strategy

### 7.1 Unit Tests (No Model Required)

All tests use `MockQwenCloneInferrer` (actor conforming to `QwenCloneInferring`):

- `QwenCloneConfigurationTests` — locale mapping, supports check
- `QwenCloneSpeechServiceTests` — speak, stop, timeout, truncation, queue, metrics
- `QwenCloneModelManagerTests` — state transitions, unload, isModelCached
- `TTSEngineSelectorVoiceCloneTests` — routing, fallback, priority chain

### 7.2 Integration Tests (Model Required)

Manual on hardware:
- Download + cache verification
- Voice cloning quality (EN reference → EN/ES/FR output)
- Latency benchmarks
- Memory profiling

---

## 8. Migration Plan (from CSM-1B)

### 8.1 Files to Delete

```
Core/VoiceCloning/CSMConfiguration.swift
Core/VoiceCloning/CSMInferring.swift
Core/VoiceCloning/CSMClient.swift
Core/VoiceCloning/CSMProcessManager.swift
Core/VoiceCloning/CSMModelManager.swift
Core/VoiceCloning/CSMSpeechService.swift
Resources/CSM/csm_server.py
Resources/CSM/setup_csm_env.sh
Tests/CSMConfigurationTests.swift
Tests/CSMClientTests.swift
Tests/CSMModelManagerTests.swift
Tests/CSMSpeechServiceTests.swift
Tests/TTSEngineSelectorCSMTests.swift
Tests/Mocks/MockCSMInferrer.swift
```

### 8.2 Files to Create

```
Core/VoiceCloning/QwenCloneConfiguration.swift
Core/VoiceCloning/QwenCloneInferring.swift
Core/VoiceCloning/QwenCloneClient.swift
Core/VoiceCloning/QwenCloneModelManager.swift
Core/VoiceCloning/QwenCloneSpeechService.swift
Tests/QwenCloneConfigurationTests.swift
Tests/QwenCloneSpeechServiceTests.swift
Tests/QwenCloneModelManagerTests.swift
Tests/TTSEngineSelectorVoiceCloneTests.swift
Tests/Mocks/MockQwenCloneInferrer.swift
```

### 8.3 Files to Modify

```
TTSEngine.swift           — .csm → .voiceClone, supports() updated
TTSEngineSelector.swift   — CSM refs → QwenClone refs
ContentView.swift         — isCSMDownloading → isVoiceCloneDownloading
LanguagePairView.swift    — same logic, engine names
AudioViewModel.swift      — minimal (same wiring pattern)
TTSEngineTests.swift      — update .csm → .voiceClone
```

---

## 9. Answers to Open Questions

| OQ | Answer |
|----|--------|
| OQ-1 Quantization | **8-bit default** for best quality. Make configurable for 4-bit on 8 GB machines. |
| OQ-2 Streaming | **Batch-only for F7.2**. mlx-audio-swift streaming emits events, not chunked audio. Future optimisation. |
| OQ-3 Concurrent MLX | **Unload Kokoro before loading Qwen3-TTS**. One MLX TTS model at a time. Parakeet STT can coexist (different pipeline stage). |
| OQ-4 Model unload | **Set model to nil** + `MLX.GPU.clearCache()`. Verify with Instruments. |
| OQ-5 Cache location | **Use HuggingFace default** (`~/.cache/huggingface/hub/`). Standard location, no custom path needed. |
| OQ-6 Voice profile resampling | **Pass raw 24 kHz samples** — matches Qwen3-TTS expected rate. No resampling needed. |

---

*This document defines **how** the system is built. Task breakdown and implementation order are in `tasks.md`.*
