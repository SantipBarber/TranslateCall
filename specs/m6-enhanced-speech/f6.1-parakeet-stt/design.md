# F6.1 — FluidAudio Parakeet STT: Technical Design

> **Feature**: F6.1 — FluidAudio Parakeet STT Integration
> **Milestone**: M6 — Enhanced STT/TTS
> **Status**: DRAFT
> **Depends on**: requirements.md (approved)
> **Date**: 2026-03-11

---

## 1. Architecture Overview

```
AudioCoordinator
    │
    ▼
STTEngineSelector  (@MainActor ObservableObject)
    │  selects active service based on locale + preference
    ├──▶ AppleSpeechService  (existing, for non-English / fallback)
    └──▶ ParakeetSpeechService  (new, English only)
              │
              ▼
         ParakeetModelManager  (actor, singleton)
              │  loads/caches AsrModels
              ▼
         AsrManager  (FluidAudio)
              │
              ▼
         TranscriptionResult  (existing type, unchanged)
```

### 1.1 Guiding Decisions

| Decision | Rationale |
|----------|-----------|
| Segment-based transcription (`AsrManager`) rather than `StreamingEouAsrManager` | VAD already segments audio; reuses proven pipeline without replacing VAD |
| `ParakeetSpeechService` conforms to existing `SpeechRecognizerService` protocol | Zero changes to `AudioCoordinator`; pure plug-in addition |
| `STTEngineSelector` is `@MainActor ObservableObject` (not actor) | Needs to be observed by SwiftUI views; same pattern as `VADServiceFactory` |
| `ParakeetModelManager` is a global actor-isolated singleton | Model download/load is expensive; shared across outgoing and incoming pipelines |
| English-only guard in `setLocale` | Parakeet TDT v3 is trained on English only; returning `STTError.languageUnavailable` gives `AudioCoordinator` a clean fallback signal |
| Metrics in-memory only | Privacy by design; no persistence needed for A/B comparison |

---

## 2. New Types

### 2.1 `STTEngine`

```swift
// Core/STT/STTEngine.swift
public enum STTEngine: String, Codable, Sendable, CaseIterable {
    case appleSpeech  // SFSpeechRecognizer (existing)
    case parakeet     // FluidAudio Parakeet TDT v3

    var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech"
        case .parakeet:    return "Parakeet (Enhanced)"
        }
    }

    /// Returns true when this engine can handle the given locale.
    func supports(locale: Locale) -> Bool {
        switch self {
        case .appleSpeech: return true   // delegates to SFSpeechRecognizer availability
        case .parakeet:    return locale.language.languageCode?.identifier == "en"
        }
    }
}
```

### 2.2 `STTMetrics`

```swift
// Core/STT/STTMetrics.swift
public struct STTMetrics: Sendable {
    public let engine: STTEngine
    public let segmentDurationMs: Int
    public let transcriptionLatencyMs: Int
    public let confidence: Float
    public let textLength: Int
    public let timestamp: Date
}
```

### 2.3 `ParakeetConfiguration`

```swift
// Core/STT/ParakeetConfiguration.swift
public struct ParakeetConfiguration: Sendable {
    public let modelVersion: AsrModelVersion   // default: .v3
    public let preferANE: Bool                 // default: true (uses Apple Neural Engine)

    nonisolated(unsafe) public static let `default` = ParakeetConfiguration(
        modelVersion: .v3,
        preferANE: true
    )
}
```

---

## 3. `ParakeetModelManager` (Actor)

Single shared instance responsible for the entire model lifecycle.

```swift
// Core/STT/ParakeetModelManager.swift
actor ParakeetModelManager {
    static let shared = ParakeetModelManager()

    enum State: Sendable {
        case idle           // never loaded
        case downloading    // download in progress
        case loading        // AsrModels.loadFromCache in progress
        case ready(AsrManager)
        case failed(Error)  // terminal; user must retry
    }

    private(set) var state: State = .idle

    // Initialise from cache if available, else download.
    func ensureReady(config: ParakeetConfiguration) async throws -> AsrManager

    // Force re-download (called from Settings).
    func redownload(config: ParakeetConfiguration) async throws

    // Release CoreML model memory.
    func unload()

    // Internal helpers
    private func download(config: ParakeetConfiguration) async throws -> AsrManager
    private func loadFromCache(config: ParakeetConfiguration) async throws -> AsrManager
}
```

#### 3.1 `ensureReady` flow

```
ensureReady()
  ├── state == .ready(mgr)  →  return mgr  (fast path)
  ├── state == .downloading / .loading  →  await continuation (wait for in-flight task)
  ├── AsrModels.loadFromCache() succeeds  →  state = .ready(mgr); return mgr
  └── loadFromCache() throws  →  AsrModels.downloadAndLoad()
        ├── success  →  state = .ready(mgr); return mgr
        └── failure  →  state = .failed(err); throw
```

#### 3.2 MLModelConfiguration

```swift
let mlConfig = MLModelConfiguration()
mlConfig.computeUnits = config.preferANE ? .all : .cpuAndGPU
```

---

## 4. `ParakeetSpeechService` (Actor)

```swift
// Core/STT/ParakeetSpeechService.swift
actor ParakeetSpeechService: SpeechRecognizerService {

    // MARK: - SpeechRecognizerService
    nonisolated(unsafe) private(set) var locale: Locale
    var transcriptionStream: AsyncStream<TranscriptionResult> { get }

    func activate() async throws
    func deactivate() async
    func setLocale(_ locale: Locale) throws   // throws STTError.languageUnavailable for non-en

    // MARK: - Internal
    private let configuration: STTConfiguration
    private let parakeetConfig: ParakeetConfiguration
    private var continuation: AsyncStream<TranscriptionResult>.Continuation?
    private let metricsCollector: STTMetricsCollector
}
```

#### 4.1 `activate()` sequence

```
activate()
  1. Guard locale is English → else throw STTError.languageUnavailable
  2. await ParakeetModelManager.shared.ensureReady(config: parakeetConfig)
     → may trigger download sheet (see §7 UI)
  3. Create AsyncStream<TranscriptionResult>, store continuation
  4. Set internal state = .active
```

#### 4.2 `transcribe(segment:)` — internal method called by pipeline

```
transcribe(segment: SpeechSegment)
  1. Capture start = ContinuousClock.now
  2. Extract [Float] from segment.buffer (already 16kHz mono)
     → Truncate to ASRConstants.maxModelSamples if needed (REQ-PAR-10)
  3. let result = try await asrManager.transcribe(samples, source: .microphone)
  4. let latency = ContinuousClock.now - start  (milliseconds)
  5. metricsCollector.record(STTMetrics(engine: .parakeet, latency: latency, …))
  6. if result.confidence < configuration.minimumConfidence → return (discard)
  7. continuation?.yield(TranscriptionResult(
         text: result.text,
         confidence: result.confidence,
         locale: locale,
         timestamp: segment.capturedAt
     ))
```

#### 4.3 Buffer extraction helper

```swift
// Shared helper (added to AVAudioPCMBuffer extension or SpeechRecognizerService.swift)
extension AVAudioPCMBuffer {
    func toFloatArray() -> [Float] {
        guard let channelData = floatChannelData else { return [] }
        let count = Int(frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }
}
```

#### 4.4 Non-English guard

```swift
func setLocale(_ locale: Locale) throws {
    guard locale.language.languageCode?.identifier == "en" else {
        throw STTError.languageUnavailable
    }
    self.locale = locale
}
```

---

## 5. `STTEngineSelector` (@MainActor ObservableObject)

Replaces the direct `AppleSpeechService` usage in `AudioCoordinator`. Both pipelines (outgoing + incoming) share the same selector.

```swift
// Core/STT/STTEngineSelector.swift
@MainActor
final class STTEngineSelector: ObservableObject {
    @Published private(set) var activeEngine: STTEngine = .appleSpeech
    @Published private(set) var parakeetAvailable: Bool = false
    @Published private(set) var usingFallback: Bool = false   // true when Parakeet selected but Apple Speech is active

    // Persisted preference
    @Published var preferredEngine: STTEngine {
        didSet { persist() }
    }

    // Active service instances
    private(set) var outgoingService: any SpeechRecognizerService
    private(set) var incomingService: any SpeechRecognizerService

    init(defaults: UserDefaults = .standard,
         appleSpeechFactory: () -> any SpeechRecognizerService,
         parakeetFactory: () -> any SpeechRecognizerService)

    // Called when source/target locale changes
    func updateLocales(source: Locale, target: Locale) async

    // Called from Settings UI
    func setPreference(_ engine: STTEngine) async
}
```

#### 5.1 Engine resolution logic

```
updateLocales(source:, target:)
  ├── preferred == .parakeet AND source.languageCode == "en"
  │     AND parakeetAvailable
  │     → outgoingService = ParakeetSpeechService
  │       incomingService = AppleSpeechService (remote speaker; unknown language)
  │       usingFallback = false
  ├── preferred == .parakeet AND (source != en OR !parakeetAvailable)
  │     → both services = AppleSpeechService
  │       usingFallback = true
  └── preferred == .appleSpeech
        → both services = AppleSpeechService
          usingFallback = false
```

**Rationale**: The incoming pipeline always uses Apple Speech because the remote speaker's language is the *target* language (non-English in most cross-language calls).

#### 5.2 `AudioCoordinator` changes

Minimal: replace two `AppleSpeechService` instantiation sites with `STTEngineSelector` factory injection.

```swift
// Before (AudioCoordinator.swift):
private var outgoingSTT: any SpeechRecognizerService
private var incomingSTT: any SpeechRecognizerService

// After:
private var engineSelector: STTEngineSelector
// outgoingSTT → engineSelector.outgoingService
// incomingSTT → engineSelector.incomingService
```

---

## 6. `STTMetricsCollector` (Actor)

```swift
// Core/STT/STTMetricsCollector.swift
actor STTMetricsCollector {
    static let shared = STTMetricsCollector()

    private(set) var recent: [STTMetrics] = []   // capped at 100 entries
    private let cap = 100

    func record(_ metrics: STTMetrics) {
        recent.append(metrics)
        if recent.count > cap { recent.removeFirst() }
    }

    func summary(for engine: STTEngine) -> (avgLatencyMs: Double, avgConfidence: Double) {
        let filtered = recent.filter { $0.engine == engine }
        guard !filtered.isEmpty else { return (0, 0) }
        let latency = filtered.map { Double($0.transcriptionLatencyMs) }.reduce(0, +) / Double(filtered.count)
        let conf = filtered.map { Double($0.confidence) }.reduce(0, +) / Double(filtered.count)
        return (latency, conf)
    }
}
```

---

## 7. UI Changes

### 7.1 Model Download Sheet

Presented as a `.sheet` from `ContentView` when `ParakeetModelManager.state == .downloading`:

```
┌─────────────────────────────────────┐
│  Downloading Parakeet model         │
│  ≈ 800 MB · One-time download       │
│                                     │
│  [===================    ] (spinner)│
│                                     │
│  [Cancel]                           │
└─────────────────────────────────────┘
```

- Uses indeterminate `ProgressView()` (no byte-level progress available from `AsrModels.downloadAndLoad`)
- Cancel → calls `ParakeetModelManager.shared.unload()`, reverts preference to `.appleSpeech`

### 7.2 Engine Selector (in LanguagePairView or new STT section)

```
STT Engine
  ○ Apple Speech     (always available)
  ● Parakeet         (English only · ~800 MB · [Download])
      ⚠ Parakeet: English only — using Apple Speech   ← shown when usingFallback == true
```

- Picker is `Picker("STT Engine", selection: $selector.preferredEngine)` with `.pickerStyle(.radioGroup)`.
- Parakeet row is disabled when `!selector.parakeetAvailable`.
- "Download" button triggers `ParakeetModelManager.shared.redownload()`.

### 7.3 A/B Metrics Panel

Expandable section at bottom of main window or separate tab:

```
┌─────────────────────────────────────────────────┐
│ STT Performance  (last 50 segments)             │
│                                                 │
│             Apple Speech    Parakeet            │
│  Avg latency    423 ms       312 ms             │
│  Avg confidence  0.82         0.91              │
│  Segments          12           8               │
└─────────────────────────────────────────────────┘
```

New `STTMetricsView` — reads from `STTMetricsCollector.shared`.

---

## 8. Data Flow (Happy Path)

```
Mic → AudioManager (48kHz) → 16kHz resample → VAD
    → SpeechSegment
    → STTEngineSelector.outgoingService (= ParakeetSpeechService)
        → ParakeetModelManager.ensureReady()
        → segment.buffer.toFloatArray()  (already 16kHz)
        → AsrManager.transcribe([Float], source: .microphone)
        → STTMetricsCollector.shared.record(…)
        → TranscriptionResult
    → TranslationBridge
    → TTS → BlackHole
```

---

## 9. Error Handling

| Error | Source | Handling |
|-------|--------|----------|
| `ASRError.notInitialized` | Transcription before model loaded | Rethrow as `STTError.failure("parakeet_not_ready")`; `AudioCoordinator` logs and continues |
| `ASRError.invalidAudioData` | Bad buffer format | Rethrow as `STTError.failure("invalid_audio")`; segment discarded |
| `ASRError.processingFailed` | CoreML inference error | Rethrow as `STTError.failure(description)`; segment discarded |
| `AsrModelsError.downloadFailed` | Network error | `ParakeetModelManager.state = .failed`; alert shown; engine reverts |
| `STTError.languageUnavailable` | Non-English locale | Caught by `STTEngineSelector`; route to `AppleSpeechService` |
| Model files deleted mid-session | File system change | `loadFromCache` throws → `ensureReady` retriggers download flow |

---

## 10. File Map

```
TranslateCall/
└── Core/
    └── STT/
        ├── SpeechRecognizerService.swift     (existing — add STTEngine, STTMetrics)
        ├── AppleSpeechService.swift          (existing — unchanged)
        ├── STTEngine.swift                   (NEW)
        ├── STTMetrics.swift                  (NEW)
        ├── STTMetricsCollector.swift         (NEW)
        ├── ParakeetConfiguration.swift       (NEW)
        ├── ParakeetModelManager.swift        (NEW)
        └── ParakeetSpeechService.swift       (NEW)
        └── STTEngineSelector.swift           (NEW)
└── Features/
    └── Main/
        ├── STTMetricsView.swift              (NEW)
        └── LanguagePairView.swift            (MODIFIED — engine picker + fallback badge)
└── App/
    └── ContentView.swift                     (MODIFIED — model download sheet)
```

---

## 11. Testing Strategy

| Test class | What it covers |
|------------|----------------|
| `STTEngineTests` | `STTEngine.supports(locale:)` for en/fr/de/zh; `displayName` |
| `STTMetricsCollectorTests` | `record`, `summary`, cap at 100 entries |
| `ParakeetModelManagerTests` | State machine; mock `AsrModels` load/fail paths |
| `ParakeetSpeechServiceTests` | `setLocale` guard; confidence filter; truncation at 240k samples; `STTError` mapping |
| `STTEngineSelectorTests` | Engine resolution for en/non-en + parakeet available/unavailable; fallback badge; UserDefaults persistence |
| `ParakeetIntegrationTests` | (requires device) Real transcription of a reference .wav; latency ≤ 800ms; confidence ≥ 0.75 |

All unit tests use mock `AsrManager` (protocol extracted or overridden via subclass/actor) — no real model download in unit tests.

---

## 12. Open Questions

| # | Question | Owner | Target |
|---|----------|-------|--------|
| 1 | Does `AsrModels.downloadAndLoad` expose byte-level download progress? If yes, use `ProgressView(value:total:)` instead of indeterminate. | Dev | T2 spike |
| 2 | Should `incomingService` ever use Parakeet? (Remote speaker might be English.) Decision: always Apple Speech for incoming to avoid latency uncertainty. | Product | Pre-T5 |
| 3 | Is `AsrManager` safe to call concurrently from two actors (outgoing + incoming pipelines)? If not, `ParakeetModelManager` must serialize calls. | Dev | T3 spike |
