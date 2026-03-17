# F8.1 — whisper.cpp STT Integration — Technical Design

## 1. Technology Decision: WhisperKit

**Chosen**: [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax (MIT license)

| Option | SPM | Performance | Maintenance | Decision |
|--------|-----|-------------|-------------|----------|
| WhisperKit | 1-line SPM | CoreML + ANE | Active (0.9.x) | **CHOSEN** |
| whisper.cpp direct | Poor (C API, unsafe flags) | Metal | Very active | Rejected — integration friction |
| SwiftWhisper | SPM (branch-only) | Good | Stale (2023) | Rejected — unmaintained |

**Rationale**: WhisperKit is purpose-built for Apple Silicon, uses CoreML/ANE for best performance, has a clean Swift API, and integrates via standard SPM. The tradeoff (CoreML-only, no GGML) is acceptable since we target macOS 15+ exclusively.

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    STTEngineSelector                     │
│  .appleSpeech → AppleSpeechService                      │
│  .parakeet    → ParakeetSpeechService (EN only)         │
│  .whisper     → WhisperSpeechService (99+ languages)    │ ← NEW
└──────────────┬──────────────────────────────────────────┘
               │ makeOutgoingService(for:) / makeIncomingService(for:)
               ▼
┌──────────────────────────────┐
│   WhisperSpeechService       │ ← NEW actor
│   conforms: SpeechRecognizerService │
│                              │
│   - transcriptionStream      │
│   - activate(stream:)        │
│   - deactivate()             │
│   - setLocale()              │
│                              │
│   Uses: WhisperModelManager  │
└──────────────┬───────────────┘
               │ ensureReady()
               ▼
┌──────────────────────────────┐
│   WhisperModelManager        │ ← NEW singleton actor
│                              │
│   - ensureReady(config:)     │
│   - downloadModel(size:)     │
│   - unloadModel()            │
│   - isReady / isDownloading  │
│   - downloadProgress         │
│                              │
│   Wraps: WhisperKit pipe     │
└──────────────────────────────┘
```

## 3. WhisperSpeechService — Implementation Design

### Protocol Conformance

```swift
actor WhisperSpeechService: SpeechRecognizerService {
    nonisolated let transcriptionStream: AsyncStream<TranscriptionResult>
    nonisolated private(set) var locale: Locale

    private var continuation: AsyncStream<TranscriptionResult>.Continuation?
    private var processingTask: Task<Void, Never>?
    private let config: STTConfiguration
    private let whisperConfig: WhisperConfiguration
    private let pipeFactory: @Sendable () async throws -> WhisperKit

    init(
        locale: Locale,
        config: STTConfiguration = .default,
        whisperConfig: WhisperConfiguration = .default,
        pipeFactory: @Sendable @escaping () async throws -> WhisperKit = {
            try await WhisperModelManager.shared.ensureReady()
        }
    )

    func activate(stream: AsyncStream<SpeechSegment>) async throws
    func deactivate() async
    func setLocale(_ locale: Locale) async
}
```

### Transcription Flow

```
SpeechSegment (16kHz mono Float32)
    │
    ▼
Extract pcmFloat32Array from AVAudioPCMBuffer
    │
    ▼
Truncate to 30s (480,000 samples) if needed
    │
    ▼
pipe.transcribe(audioArray: samples, decodeOptions: options)
    │  ← options include language code from locale
    ▼
TranscriptionResult(text:, confidence:, locale:, capturedAt:, audioDuration:)
    │
    ▼
Emit via continuation (if confidence >= config.minimumConfidence)
```

### Key Design Points

1. **Lazy pipe loading**: `pipeFactory` is called on first `activate()`, not in init. This avoids loading the model until the user actually starts a session. The pipe is retained across activations.

2. **Dependency injection**: `pipeFactory` defaults to `WhisperModelManager.shared.ensureReady()` but can be injected for tests (mock `WhisperKit` or preloaded instance).

3. **Language setting**: WhisperKit's `DecodingOptions` accepts a `language` parameter. We map `locale.language.languageCode?.identifier` to Whisper's language code. If `nil` or unmapped, Whisper auto-detects.

4. **Confidence extraction**: WhisperKit returns `TranscriptionResult` with segments. We compute mean confidence from segment-level log probabilities: `confidence = exp(meanLogProb)`. If WhisperKit doesn't expose per-word confidence, we use the segment-level `avgLogprob` field.

5. **Metrics**: Record `STTMetrics(engine: .whisper, latencyMs:, segmentDurationMs:, confidence:, textLength:)` consistent with existing services.

6. **Max segment length**: WhisperKit handles up to 30 seconds. Segments from VAD are typically 1-10 seconds. If a segment exceeds 30s, truncate from the end (keep the start of the utterance).

## 4. WhisperModelManager — Implementation Design

### Singleton Actor Pattern

```swift
actor WhisperModelManager {
    static let shared = WhisperModelManager()

    // Observable state (nonisolated for UI binding)
    @Published private(set) var isReady: Bool = false
    @Published private(set) var isDownloading: Bool = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var currentModelSize: WhisperModelSize = .base
    @Published private(set) var error: Error?

    private var pipe: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?

    func ensureReady(config: WhisperConfiguration = .default) async throws -> WhisperKit
    func downloadModel(size: WhisperModelSize) async throws
    func unloadModel()
}
```

Wait — actors can't have `@Published` properties. Use the same pattern as `ParakeetModelManager`: publish state changes manually via `@MainActor` hops, or use a separate `@MainActor ObservableObject` for state. Let me check the existing pattern.

### State Publishing Pattern (from ParakeetModelManager)

`ParakeetModelManager` is an actor that mutates state internally. The `STTEngineSelector` (@MainActor) observes readiness by checking `ParakeetModelManager.shared` directly. The manager exposes simple properties:

```swift
actor WhisperModelManager {
    static let shared = WhisperModelManager()

    private(set) var isReady: Bool = false
    private(set) var isDownloading: Bool = false
    private(set) var downloadProgress: Double = 0
    private(set) var currentModelSize: WhisperModelSize = .base
    private(set) var loadError: Error?

    private var pipe: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?

    // Task coalescing: concurrent calls share one load operation
    func ensureReady(
        config: WhisperConfiguration = .default
    ) async throws -> WhisperKit {
        if let pipe { return pipe }
        if let loadTask { return try await loadTask.value }

        let task = Task {
            isDownloading = true
            defer { isDownloading = false }
            let kit = try await WhisperKit(
                WhisperKitConfig(model: config.modelSize.whisperKitName)
            )
            self.pipe = kit
            self.isReady = true
            return kit
        }
        loadTask = task
        return try await task.value
    }

    func unloadModel() {
        pipe = nil
        loadTask = nil
        isReady = false
    }
}
```

### Model Size Mapping

```swift
enum WhisperModelSize: String, Codable, Sendable, CaseIterable {
    case tiny       // ~75 MB
    case base       // ~150 MB
    case small      // ~500 MB
    case medium     // ~1.5 GB
    case largeV3    // ~3 GB

    var whisperKitName: String {
        switch self {
        case .tiny:    return "openai_whisper-tiny"
        case .base:    return "openai_whisper-base"
        case .small:   return "openai_whisper-small"
        case .medium:  return "openai_whisper-medium"
        case .largeV3: return "openai_whisper-large-v3"
        }
    }

    var approximateSizeMB: Int { ... }
    var qualityDescription: String { ... }
}
```

> Note: Exact WhisperKit model names need verification during implementation. WhisperKit auto-downloads from `argmaxinc/whisperkit-coreml` on HuggingFace.

## 5. WhisperConfiguration

```swift
struct WhisperConfiguration: Sendable {
    var modelSize: WhisperModelSize = .base
    var language: String? = nil  // nil = auto-detect
    var beamSize: Int = 5
    var noSpeechThreshold: Float = 0.6

    nonisolated static let `default` = WhisperConfiguration()
}
```

## 6. STTEngine & STTEngineSelector Changes

### STTEngine Extension

```swift
enum STTEngine: String, Codable, Sendable, CaseIterable {
    case appleSpeech
    case parakeet
    case whisper       // ← NEW

    func supports(locale: Locale) -> Bool {
        switch self {
        case .appleSpeech: return true  // system handles availability
        case .parakeet:    return locale.isEnglish
        case .whisper:     return WhisperLanguages.supports(locale)
        }
    }
}
```

### STTEngineSelector Changes

Add to existing selector:

```swift
@Published var whisperAvailable: Bool = false
@Published var isWhisperDownloading: Bool = false

// New factory
private let whisperFactory: (Locale) -> any SpeechRecognizerService

// Updated makeOutgoingService:
func makeOutgoingService(for locale: Locale) -> any SpeechRecognizerService {
    if preferredEngine == .whisper && whisperAvailable && STTEngine.whisper.supports(locale: locale) {
        return whisperFactory(locale)
    }
    if preferredEngine == .parakeet && parakeetAvailable && locale.isEnglish {
        return parakeetFactory(locale)
    }
    return appleSpeechFactory(locale)
}

// Updated makeIncomingService — now can use Whisper too:
func makeIncomingService(for locale: Locale) -> any SpeechRecognizerService {
    if preferredEngine == .whisper && whisperAvailable && STTEngine.whisper.supports(locale: locale) {
        return whisperFactory(locale)
    }
    return appleSpeechFactory(locale)
}
```

Key difference from Parakeet: **Whisper serves both directions** since it supports most languages. Parakeet is English-only so it was outgoing-only.

### Whisper Language Support

```swift
enum WhisperLanguages {
    // Whisper supports 99 languages. Store as a static Set<String> of language codes.
    static let supported: Set<String> = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
        "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
        "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw",
        "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
        "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo",
        "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
        "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
        "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
        "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
        "tr", "tt", "uk", "ur", "uz", "vi", "yi", "yo", "zh", "yue"
    ]

    static func supports(_ locale: Locale) -> Bool {
        guard let code = locale.language.languageCode?.identifier else { return false }
        return supported.contains(code)
    }
}
```

## 7. UI Changes

### LanguagePairView — Engine Picker

Add "Whisper" to the existing STT engine Picker. Same pattern as Parakeet toggle:

```swift
Picker("STT Engine", selection: $selectedSTTEngine) {
    Text("Apple Speech").tag(STTEngine.appleSpeech)
    Text("Parakeet (EN)").tag(STTEngine.parakeet)
    Text("Whisper").tag(STTEngine.whisper)           // ← NEW
}
```

### Whisper Download Sheet

When Whisper is selected but not downloaded, show a sheet with model size picker + download button. Reuse the visual pattern from Kokoro/Parakeet download sheets.

### Model Size Picker (WhisperModelSizeView)

```
┌─────────────────────────────────────────┐
│  Select Whisper Model                    │
│                                          │
│  ○ Tiny    (~75 MB)   ★☆☆☆☆  Fastest   │
│  ● Base    (~150 MB)  ★★☆☆☆  Real-time │ ← default
│  ○ Small   (~500 MB)  ★★★☆☆  Good      │
│  ○ Medium  (~1.5 GB)  ★★★★☆  High      │
│  ○ Large   (~3 GB)    ★★★★★  Best      │
│                                          │
│  [Download]                              │
└─────────────────────────────────────────┘
```

### Fallback Badge

Same `usingFallback` pattern: if Whisper is preferred but not available (not downloaded or locale unsupported), show "Using Apple Speech" badge.

## 8. File Structure

```
TranslateCall/Core/STT/
├── AppleSpeechService.swift         (existing)
├── AsrTranscriber.swift             (existing)
├── ParakeetConfiguration.swift      (existing)
├── ParakeetModelManager.swift       (existing)
├── ParakeetSpeechService.swift      (existing)
├── SpeechRecognizerService.swift    (existing)
├── STTEngine.swift                  (MODIFY — add .whisper)
├── STTEngineSelector.swift          (MODIFY — add Whisper routing)
├── STTMetrics.swift                 (existing, no change)
├── STTMetricsCollector.swift        (existing, no change)
├── WhisperConfiguration.swift       (NEW)
├── WhisperLanguages.swift           (NEW)
├── WhisperModelManager.swift        (NEW)
└── WhisperSpeechService.swift       (NEW)
```

## 9. SPM Dependency

Add to `Package.swift` / Xcode SPM:

```
https://github.com/argmaxinc/WhisperKit.git
```

Minimum version: latest stable (currently 0.9.x). Pin to minor version.

## 10. Testing Strategy

| Test | Type | Description |
|------|------|-------------|
| WhisperSpeechServiceTests | Unit | Mock pipe factory, verify protocol conformance, transcription flow, locale switching |
| WhisperModelManagerTests | Unit | Task coalescing, download state, unload |
| WhisperConfigurationTests | Unit | Default values, model size mapping |
| WhisperLanguagesTests | Unit | Language code lookup for 10+ locales including `uk` |
| STTEngineSelectorWhisperTests | Unit | Routing logic: Whisper preferred → Whisper available → correct service returned |
| Integration | Manual | Real model download + transcription of EN/UK/ES audio samples |

Mock strategy: `WhisperSpeechService` accepts a `pipeFactory` closure. Tests inject a mock that returns pre-canned results without loading a CoreML model.

## 11. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| WhisperKit API breaking changes | Pin SPM version; wrap in our protocol |
| Large model download fails | Resume support (WhisperKit uses HuggingFace Hub which supports range requests) |
| CoreML compilation slow on first run | WhisperKit pre-compiles models; show "Preparing model..." state |
| Memory pressure with large models | Default to `base`; expose model unload; document RAM requirements per size |
| WhisperKit doesn't expose word-level confidence | Use segment-level `avgLogprob`; document lower confidence granularity |
