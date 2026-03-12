# F6.2 — MLX-Audio Kokoro TTS: Technical Design

> **Feature**: F6.2 — MLX-Audio Kokoro TTS Integration
> **Milestone**: M6 — Enhanced STT/TTS
> **Status**: DRAFT
> **Author**: SDD Process
> **Date**: 2026-03-12
> **Depends on**: F6.1 (patterns established by STTEngine, STTMetrics, STTEngineSelector, ParakeetModelManager)

---

## 1. Overview & Key Decisions

### 1.1 Package Choice: FluidAudio `FluidAudioTTS`

We reuse the **FluidAudio** package already integrated in F6.1 (Parakeet STT). FluidAudio v0.7.7+ ships a separate `FluidAudioTTS` product that wraps the Kokoro-82M CoreML model. This is the right choice because:

- **Zero new SPM dependencies** — FluidAudio is already pinned in the project.
- **CoreML/ANE with no GPL** — v0.12.3 replaced eSpeak NG with a CoreML G2P model; clean license.
- **Production-ready** — shipped by FluidInference, actively maintained.
- **Simple API** — `KokoroTtsManager.initialize()` + `synthesize(text:)` → `Data` (24 kHz WAV).

**SPM product to add**: `"FluidAudioTTS"` (renamed from `"FluidAudioWithTTS"` in v0.12.3; current pinned version is 0.12.2 — bump to 0.12.3).

### 1.2 English-Only Scope (M6)

`KokoroTtsManager` in FluidAudio currently synthesises **American English only** (upstream model supports 8 languages but the CoreML wrapper is English-only). This aligns with M6 scope: Kokoro is offered as the high-quality engine for English synthesis; `AVSpeechService` handles all other languages automatically. Multi-language Kokoro support is tracked in the risk registry and can be enabled in M8 if FluidAudio ships it.

### 1.3 Architecture Mirror

F6.2 deliberately mirrors the F6.1 architecture. Every new type has a direct STT counterpart:

| TTS (F6.2) | STT mirror (F6.1) |
|---|---|
| `TTSEngine` | `STTEngine` |
| `TTSMetrics` / `TTSMetricsSummary` | `STTMetrics` / `STTMetricsSummary` |
| `KokoroConfiguration` | `ParakeetConfiguration` |
| `KokoroModelManager` | `ParakeetModelManager` |
| `KokoroSpeechService` | `ParakeetSpeechService` |
| `TTSEngineSelector` | `STTEngineSelector` |
| `TTSMetricsCollector` | `STTMetricsCollector` |
| `TTSMetricsView` | `STTMetricsView` |

---

## 2. Component Inventory

### New files (`Core/TTS/`)

| File | Role |
|---|---|
| `TTSEngine.swift` | Enum: `.avSpeech` / `.kokoro`; `supports(locale:)`; `displayName` |
| `TTSMetrics.swift` | `TTSMetrics` struct + `TTSMetricsSummary` struct |
| `KokoroConfiguration.swift` | Config struct (voice, variant, model version) |
| `KokoroModelManager.swift` | Actor singleton; state machine; lazy load/unload |
| `KokoroSpeechService.swift` | Actor conforming to `SynthesisService` |
| `TTSEngineSelector.swift` | `@MainActor ObservableObject`; factory closures; persistence |
| `TTSMetricsCollector.swift` | Actor singleton; ring buffer; `record(_:)` / `summary(for:)` |

### New files (`Features/Main/`)

| File | Role |
|---|---|
| `TTSMetricsView.swift` | `DisclosureGroup` showing avg latency per engine |

### Modified files

| File | Change |
|---|---|
| `Features/Main/LanguagePairView.swift` | Add TTS engine picker row + fallback badge + voice selector + preview button |
| `Features/ContentView.swift` | Add `TTSMetricsView()` |
| `Features/Main/AudioViewModel.swift` | Own `TTSEngineSelector`; wire to `AudioCoordinator` |
| `Core/AudioCoordinator.swift` | Replace hardcoded `AVSpeechService` factories with `TTSEngineSelector` factories |
| `TranslateCall.xcodeproj/project.pbxproj` | Bump FluidAudio to 0.12.3; add `FluidAudioTTS` product |

---

## 3. Detailed Component Design

### 3.1 `TTSEngine.swift`

```swift
import Foundation

enum TTSEngine: String, Codable, Sendable, CaseIterable {
    case avSpeech  // AVSpeechSynthesizer — all languages, always available
    case kokoro    // FluidAudio KokoroTtsManager — English only, higher quality

    var displayName: String {
        switch self {
        case .avSpeech: return "AVSpeech"
        case .kokoro:   return "Kokoro"
        }
    }

    /// Returns true if this engine can synthesise for the given locale.
    func supports(locale: Locale) -> Bool {
        switch self {
        case .avSpeech: return true   // AVSpeech handles all languages
        case .kokoro:   return locale.isEnglish
        }
    }
}

// MARK: - Locale extension (English guard, mirrors STTEngine.swift pattern)

extension Locale {
    // Already defined in STTEngine.swift — no redefinition needed.
    // TTSEngine.supports(locale:) calls locale.isEnglish directly.
}
```

### 3.2 `TTSMetrics.swift`

```swift
import Foundation

struct TTSMetrics: Sendable {
    let engine: TTSEngine
    let synthesisLatencyMs: Int     // wall-clock ms from call to first audio frame
    let textLength: Int             // character count of the input text
    let locale: Locale
    let timestamp: Date
}

struct TTSMetricsSummary: Sendable {
    let avgLatencyMs: Double
    let count: Int

    // nonisolated(unsafe): immutable Sendable value; safe under SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor
    nonisolated(unsafe) static let empty = TTSMetricsSummary(avgLatencyMs: 0, count: 0)
}
```

### 3.3 `KokoroConfiguration.swift`

```swift
import Foundation

struct KokoroConfiguration: Sendable {
    /// Preferred voice identifier (e.g. "af_heart"). Empty string = model default.
    var voiceIdentifier: String = ""
    /// Model version string for cache invalidation.
    var modelVersion: String = "v1"
    /// UserDefaults key for voice persistence.
    static let voiceDefaultsKey = "tlk.tts.kokoro.voice"

    nonisolated(unsafe) static let `default` = KokoroConfiguration()
}
```

### 3.4 `KokoroModelManager.swift`

Mirrors `ParakeetModelManager` exactly — singleton actor with a state machine and task coalescing.

```swift
import FluidAudioTTS
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "KokoroModelManager")

actor KokoroModelManager {

    // MARK: - State machine

    enum ModelState: Sendable {
        case idle
        case loading
        case ready(KokoroTtsManager)   // manager is Sendable per FluidAudio contract
        case failed(String)
    }

    // MARK: - Singleton

    static let shared = KokoroModelManager()

    // MARK: - Internal state

    private(set) var state: ModelState = .idle
    private var loadTask: Task<KokoroTtsManager, Error>?

    private let stateContinuation: AsyncStream<ModelState>.Continuation
    let stateStream: AsyncStream<ModelState>

    // MARK: - Factory (injectable for tests)

    typealias ManagerFactory = @Sendable (KokoroConfiguration) async throws -> KokoroTtsManager

    // defaultFactory: calls KokoroTtsManager() and initialize() — must be nonisolated(unsafe)
    // because it references a @Sendable closure that may be stored as a static let
    nonisolated(unsafe) static let defaultFactory: ManagerFactory = { _ in
        let manager = KokoroTtsManager()
        try await manager.initialize()
        return manager
    }

    private let managerFactory: ManagerFactory

    // MARK: - Init

    init(managerFactory: ManagerFactory = KokoroModelManager.defaultFactory) {
        self.managerFactory = managerFactory
        var cont: AsyncStream<ModelState>.Continuation!
        stateStream = AsyncStream { cont = $0 }
        stateContinuation = cont
    }

    // MARK: - Public API

    /// Returns a ready manager, loading it if necessary. Concurrent callers share one load task.
    func ensureReady(config: KokoroConfiguration = .default) async throws -> KokoroTtsManager {
        switch state {
        case .ready(let mgr):
            return mgr
        case .loading:
            return try await loadTask!.value
        case .idle, .failed:
            return try await startLoading(config: config)
        }
    }

    func unload() {
        loadTask?.cancel()
        loadTask = nil
        transition(to: .idle)
    }

    func redownload(config: KokoroConfiguration = .default) async throws -> KokoroTtsManager {
        unload()
        return try await startLoading(config: config)
    }

    // MARK: - Private

    private func startLoading(config: KokoroConfiguration) async throws -> KokoroTtsManager {
        transition(to: .loading)
        let task = Task<KokoroTtsManager, Error> {
            try await managerFactory(config)
        }
        loadTask = task
        do {
            let mgr = try await task.value
            transition(to: .ready(mgr))
            return mgr
        } catch {
            transition(to: .failed(error.localizedDescription))
            throw error
        }
    }

    private func transition(to newState: ModelState) {
        state = newState
        stateContinuation.yield(newState)
        logger.debug("KokoroModelManager state → \(String(describing: newState))")
    }
}
```

### 3.5 `KokoroSpeechService.swift`

Conforms to `SynthesisService`. The key challenge: `KokoroTtsManager.synthesize(text:)` returns `Data` (WAV). We must:
1. Decode the WAV bytes into an `AVAudioPCMBuffer` (24 kHz mono Float32).
2. Resample 24 kHz → output device sample rate via `AVAudioConverter`.
3. Schedule through `AVAudioPlayerNode` (same engine setup as `AVSpeechService`).

```swift
import AVFoundation
import FluidAudioTTS
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "KokoroSpeechService")

actor KokoroSpeechService: SynthesisService {

    // MARK: - SynthesisService protocol

    nonisolated let isSpeakingStream: AsyncStream<Bool>
    private let speakingContinuation: AsyncStream<Bool>.Continuation

    // MARK: - Audio engine

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let outputDeviceID: AudioDeviceID?

    // MARK: - Kokoro model

    private var ttsManager: KokoroTtsManager?
    private let configuration: KokoroConfiguration
    private let modelManager: KokoroModelManager

    // MARK: - Queue

    private var isSpeaking = false
    private var pendingTexts: [(String, Locale)] = []

    // MARK: - Init

    init(
        outputDeviceID: AudioDeviceID?,
        configuration: KokoroConfiguration = .default,
        modelManager: KokoroModelManager = .shared
    ) throws {
        self.outputDeviceID = outputDeviceID
        self.configuration = configuration
        self.modelManager = modelManager

        var cont: AsyncStream<Bool>.Continuation!
        isSpeakingStream = AsyncStream { cont = $0 }
        speakingContinuation = cont

        try setupAudioEngine()
    }

    // MARK: - SynthesisService

    func speak(text: String, locale: Locale) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingTexts.append((text, locale))
        if !isSpeaking { await processNext() }
    }

    func stopSpeaking() async {
        pendingTexts.removeAll()
        playerNode.stop()
        setSpeaking(false)
    }

    func deactivate() async {
        await stopSpeaking()
        engine.stop()
    }

    // MARK: - Private: synthesis loop

    private func processNext() async {
        guard let (text, locale) = pendingTexts.first else {
            setSpeaking(false)
            return
        }
        pendingTexts.removeFirst()
        setSpeaking(true)

        let startDate = Date()
        do {
            let manager = try await modelManager.ensureReady(config: configuration)
            let wavData = try await manager.synthesize(text: text)
            let latencyMs = Int(Date().timeIntervalSince(startDate) * 1000)

            if let buffer = decodeWav(wavData) {
                scheduleBuffer(buffer)
            }

            Task {
                await TTSMetricsCollector.shared.record(
                    TTSMetrics(
                        engine: .kokoro,
                        synthesisLatencyMs: latencyMs,
                        textLength: text.count,
                        locale: locale,
                        timestamp: .now
                    )
                )
            }
        } catch {
            logger.error("Kokoro synthesis failed: \(error.localizedDescription)")
            setSpeaking(false)
        }

        await processNext()
    }

    // MARK: - Private: audio pipeline

    private func setupAudioEngine() throws {
        engine.attach(playerNode)
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        engine.connect(playerNode, to: mixer, format: nil)
        engine.connect(mixer, to: engine.outputNode, format: outputFormat)
        if let deviceID = outputDeviceID {
            routeToDevice(deviceID)
        }
        try engine.start()
    }

    private func routeToDevice(_ deviceID: AudioDeviceID) {
        // Same CoreAudio property-set pattern as AVSpeechService
        var deviceIDVar = deviceID
        AudioUnitSetProperty(
            engine.outputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDVar,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    /// Decodes 24 kHz mono WAV Data → AVAudioPCMBuffer at the engine's output sample rate.
    private func decodeWav(_ data: Data) -> AVAudioPCMBuffer? {
        // Step 1: wrap Data in AVAudioFile via a temporary file
        // Step 2: convert 24kHz → output sample rate via AVAudioConverter
        // (Full implementation in tasks.md T3)
        guard let kokoroFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ) else { return nil }

        let frameCount = AVAudioFrameCount((data.count - 44) / MemoryLayout<Int16>.size) // skip WAV header
        guard let kokoroBuf = AVAudioPCMBuffer(pcmFormat: kokoroFormat, frameCapacity: frameCount) else { return nil }
        kokoroBuf.frameLength = frameCount

        // Copy Int16 samples → Float32
        data.withUnsafeBytes { raw in
            let src = raw.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Int16.self)
            let dst = kokoroBuf.floatChannelData![0]
            for i in 0..<Int(frameCount) {
                dst[i] = Float(src[i]) / 32768.0
            }
        }

        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        guard outputFormat.sampleRate != 24_000 else { return kokoroBuf }

        // SRC: 24kHz → output device rate
        guard let converter = AVAudioConverter(from: kokoroFormat, to: outputFormat) else { return nil }
        let ratio = outputFormat.sampleRate / 24_000
        let outFrames = AVAudioFrameCount(Double(frameCount) * ratio)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outFrames) else { return nil }

        var inputConsumed = false
        let status = converter.convert(to: outBuf, error: nil) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return kokoroBuf
        }
        return status == .error ? nil : outBuf
    }

    private func scheduleBuffer(_ buffer: AVAudioPCMBuffer) {
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
            Task { await self?.bufferCompleted() }
        })
        if !playerNode.isPlaying { playerNode.play() }
    }

    private func bufferCompleted() async {
        if pendingTexts.isEmpty {
            setSpeaking(false)
        } else {
            await processNext()
        }
    }

    private func setSpeaking(_ value: Bool) {
        isSpeaking = value
        speakingContinuation.yield(value)
    }
}
```

> **Implementation note for decodeWav**: The WAV header parsing above is a simplified sketch. The full implementation uses `AVAudioFile(forReading:)` via a `FileManager.default.temporaryDirectory` write to avoid manual header parsing. Details in tasks.md T3.

### 3.6 `TTSMetricsCollector.swift`

Exact mirror of `STTMetricsCollector`:

```swift
actor TTSMetricsCollector {
    static let shared = TTSMetricsCollector()
    private var recent: [TTSMetrics] = []
    private let cap = 100

    func record(_ metrics: TTSMetrics) {
        recent.append(metrics)
        if recent.count > cap { recent.removeFirst() }
    }

    func summary(for engine: TTSEngine) -> TTSMetricsSummary {
        let filtered = recent.filter { $0.engine == engine }
        guard !filtered.isEmpty else { return .empty }
        let avgLatency = Double(filtered.map(\.synthesisLatencyMs).reduce(0, +)) / Double(filtered.count)
        return TTSMetricsSummary(avgLatencyMs: avgLatency, count: filtered.count)
    }

    func reset() { recent.removeAll() }
}
```

### 3.7 `TTSEngineSelector.swift`

Mirrors `STTEngineSelector`. Owns `KokoroModelManager` observation and `SynthesisService` factories.

```swift
import Combine
import Foundation

@MainActor
final class TTSEngineSelector: ObservableObject {

    // MARK: - Published state

    @Published private(set) var preferredEngine: TTSEngine = .avSpeech
    @Published private(set) var kokoroAvailable: Bool = false
    @Published private(set) var isDownloading: Bool = false
    @Published private(set) var currentTargetLocale: Locale = Locale.current

    var usingFallback: Bool {
        preferredEngine == .kokoro && !currentTargetLocale.isEnglish
    }

    // MARK: - UserDefaults

    private let defaults: UserDefaults
    private static let engineKey = "tlk.tts.engine"

    // MARK: - Factories (injectable for tests)

    var avSpeechFactory: (AudioDeviceID?) throws -> any SynthesisService = { id in
        try AVSpeechService(outputDeviceID: id)
    }
    var kokoroFactory: (AudioDeviceID?, KokoroConfiguration) throws -> any SynthesisService = { id, config in
        try KokoroSpeechService(outputDeviceID: id, configuration: config)
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.engineKey),
           let engine = TTSEngine(rawValue: raw) {
            preferredEngine = engine
        }
        observeModelManager()
    }

    // MARK: - Public API

    func setPreferredEngine(_ engine: TTSEngine) {
        preferredEngine = engine
        defaults.set(engine.rawValue, forKey: Self.engineKey)
    }

    func makeOutgoingService(for locale: Locale, deviceID: AudioDeviceID?) throws -> any SynthesisService {
        currentTargetLocale = locale
        guard preferredEngine == .kokoro, kokoroAvailable, locale.isEnglish else {
            return try avSpeechFactory(deviceID)
        }
        let voiceID = defaults.string(forKey: KokoroConfiguration.voiceDefaultsKey) ?? ""
        let config = KokoroConfiguration(voiceIdentifier: voiceID)
        return try kokoroFactory(deviceID, config)
    }

    func makeIncomingService(for locale: Locale, deviceID: AudioDeviceID?) throws -> any SynthesisService {
        // Incoming always uses AVSpeech (lower latency requirement; no Kokoro overhead)
        return try avSpeechFactory(deviceID)
    }

    func downloadKokoroModel() {
        isDownloading = true
        Task {
            do {
                _ = try await KokoroModelManager.shared.ensureReady()
            } catch {
                // State already .failed; UI reacts via stateStream
            }
            isDownloading = false
        }
    }

    func unloadKokoroModel() {
        KokoroModelManager.shared.unload()
        kokoroAvailable = false
    }

    // MARK: - For testing

    func setKokoroAvailableForTesting(_ value: Bool) { kokoroAvailable = value }

    // MARK: - Private

    private func observeModelManager() {
        Task { [weak self] in
            for await state in KokoroModelManager.shared.stateStream {
                await MainActor.run {
                    switch state {
                    case .ready:   self?.kokoroAvailable = true
                    case .failed:  self?.kokoroAvailable = false
                    case .loading: break
                    case .idle:    self?.kokoroAvailable = false
                    }
                }
            }
        }
    }
}
```

---

## 4. AudioCoordinator Integration

`AudioCoordinator` currently creates TTS services via hardcoded factories:

```swift
// Current (M5)
outgoingTTSFactory: { try AVSpeechService(outputDeviceID: $0) },
incomingTTSFactory: { _ in try AVSpeechService(outputDeviceID: nil) },
```

**New approach**: `AudioViewModel` owns a `TTSEngineSelector` (parallel to `engineSelector: STTEngineSelector`) and passes its factories to `AudioCoordinator`:

```swift
// AudioViewModel.init (updated)
let ttsSelector = TTSEngineSelector()
let coordinator = AudioCoordinator(
    ...
    outgoingTTSFactory: { [ttsSelector] deviceID in
        let locale = lpm.targetLanguage     // target = outgoing TTS language
        return try ttsSelector.makeOutgoingService(for: locale, deviceID: deviceID)
    },
    incomingTTSFactory: { [ttsSelector] deviceID in
        let locale = lpm.sourceLanguage     // source = incoming TTS language
        return try ttsSelector.makeIncomingService(for: locale, deviceID: deviceID)
    },
    ...
)
self.ttsEngineSelector = ttsSelector
```

`AudioCoordinator` itself needs no changes — only the factory closures change.

---

## 5. UI Changes

### 5.1 LanguagePairView additions

New row below the existing engine selector (outgoing section):

```
[TTS: AVSpeech | Kokoro ▼]     ← TTSEngine picker (segmented)
   Kokoro: English only — using AVSpeech   ← fallback badge (when usingFallback)
   Voice: [Heart ▼] [▶ Preview]            ← voice selector + preview (Kokoro only)
```

Binding pattern mirrors the STT engine row exactly.

### 5.2 Download sheet

Triggered by `viewModel.ttsEngineSelector.isDownloading`, parallel to the Parakeet download sheet already in `ContentView`:

```swift
.onChange(of: viewModel.ttsEngineSelector.isDownloading) { _, downloading in
    showKokoroDownload = downloading
}
```

Download sheet content: "Downloading Kokoro Model · ≈ 300 MB · One-time download".

### 5.3 TTSMetricsView

`DisclosureGroup("TTS Performance")` with a `Grid` showing:

| Engine | Avg Latency | Count |
|---|---|---|
| AVSpeech | 120 ms | 5 |
| Kokoro | 340 ms | 3 |

Placed in `ContentView` below the existing `STTMetricsView`.

---

## 6. Data Flow

```
speak(text:locale:) called by AudioCoordinator
  │
  ├── locale.isEnglish && preferredEngine == .kokoro && kokoroAvailable
  │     │
  │     ▼
  │   KokoroSpeechService.speak(text:locale:)
  │     │
  │     ├── KokoroModelManager.ensureReady()
  │     │     └── KokoroTtsManager.initialize() (first call only, cached)
  │     │
  │     ├── KokoroTtsManager.synthesize(text:) → Data (24kHz WAV)
  │     │
  │     ├── decodeWav(Data) → AVAudioPCMBuffer (24kHz Float32)
  │     │     └── AVAudioConverter: 24kHz → device rate (e.g. 48kHz)
  │     │
  │     ├── AVAudioPlayerNode.scheduleBuffer(_:completionHandler:)
  │     │
  │     └── TTSMetricsCollector.shared.record(TTSMetrics(...))
  │
  └── otherwise
        │
        ▼
      AVSpeechService.speak(text:locale:)   ← unchanged
```

---

## 7. Error Handling

| Error | Source | Handling |
|---|---|---|
| `KokoroTtsManager.initialize()` throws | `KokoroModelManager.startLoading` | State → `.failed(msg)`; `TTSEngineSelector` falls back to AVSpeech via `kokoroAvailable = false` |
| `KokoroTtsManager.synthesize()` throws | `KokoroSpeechService.processNext()` | Logged; current utterance skipped; queue continues; `setSpeaking(false)` called |
| `decodeWav` returns `nil` | `KokoroSpeechService.processNext()` | Logged; utterance skipped |
| `AVAudioEngine.start()` throws | `KokoroSpeechService.init` | `STSError.engineStartFailed` propagated to `AudioCoordinator` factory → AVSpeech used |
| `AVAudioConverter` returns `.error` | `decodeWav` | Returns `nil`; utterance skipped |

---

## 8. Testing Strategy

### Unit tests (no real model, no audio hardware)

All tests use `MockKokoroManager` — a struct conforming to a `KokoroTtsManaging` protocol, or a factory closure injection (`managerFactory`):

| Test struct | Key tests |
|---|---|
| `TTSEngineTests` | `supports(locale:)` for English / non-English; `displayName`; Codable round-trip |
| `KokoroModelManagerTests` | State transitions (.idle→.loading→.ready/.failed); concurrent coalescing (5 Tasks, factory called once); `unload()` resets to `.idle` |
| `KokoroSpeechServiceTests` | `speak()` calls factory synthesize; empty text not synthesised; `stopSpeaking()` clears queue; fallback on model error; metrics recorded |
| `TTSEngineSelectorTests` | English locale → Kokoro factory called; non-English → AVSpeech; persistence in UserDefaults; `usingFallback` computed property; `downloadKokoroModel()` sets `isDownloading` |
| `TTSMetricsCollectorTests` | Record/summary; cap at 100; engine filtering; `reset()` |

### Integration test (device-only, guarded)

```swift
@Test func kokoroSynthesisLatencyOnDevice() async throws {
    guard ProcessInfo.processInfo.environment["INTEGRATION_TESTS"] != nil else { return }
    // Load model, synthesise 10-word sentence, assert latency ≤ 600ms
}
```

### Mock types

- `MockKokoroTtsManager`: struct (or actor) implementing a `KokoroTtsManaging` protocol; `stubData: Data`; `stubError: Error?`; `callCount: Int`.
- `KokoroTtsManaging` protocol: `func synthesize(text: String) async throws -> Data` — minimal surface for injection.

> **Note**: `KokoroTtsManager` from FluidAudio is a class. We wrap it behind `KokoroTtsManaging` exactly as we wrapped `AsrManager` behind `AsrTranscriber` in F6.1. The `KokoroModelManager.managerFactory` closure returns `any KokoroTtsManaging`.

---

## 9. Package Dependency Changes

In `project.pbxproj`, bump FluidAudio from `0.12.2` → `0.12.3`:

```
minimumVersion = 0.12.3;
```

Add `FluidAudioTTS` as a linked framework to the main target (alongside the existing `FluidAudio` product for Parakeet).

---

## 10. Open Questions (to resolve during implementation)

| # | Question | Impact |
|---|---|---|
| OQ-1 | Does `KokoroTtsManager.synthesize(text:)` block the actor or return immediately with async? | Concurrency model of KokoroSpeechService queue |
| OQ-2 | Does `KokoroTtsManager` expose voice selection (e.g. via `synthesizeDetailed(text:variantPreference:)`)? If so, what is `VariantPreference`? | Voice picker UI granularity |
| OQ-3 | Does `KokoroTtsManager` auto-download the model on `initialize()`, or does it require the model to already be cached? | Download flow in KokoroModelManager |
| OQ-4 | Is `KokoroTtsManager` Sendable? | Actor isolation in KokoroModelManager state |
| OQ-5 | Exact WAV header format from `synthesize(text:)` — 44-byte standard or extended? | `decodeWav` implementation precision |

These are resolved by reading the FluidAudio source/docs at the start of the implementation task.

---

## 11. File Creation Order (dependency-safe)

1. `TTSEngine.swift` — no deps
2. `TTSMetrics.swift` — depends on `TTSEngine`
3. `KokoroConfiguration.swift` — no deps
4. `TTSMetricsCollector.swift` — depends on `TTSMetrics`
5. `KokoroModelManager.swift` — depends on `KokoroConfiguration`, `FluidAudioTTS`
6. `KokoroSpeechService.swift` — depends on `SynthesisService`, `KokoroModelManager`, `TTSMetricsCollector`
7. `TTSEngineSelector.swift` — depends on `TTSEngine`, `KokoroModelManager`, `KokoroSpeechService`, `AVSpeechService`
8. `TTSMetricsView.swift` — depends on `TTSMetricsCollector`, `TTSEngine`
9. Modify `LanguagePairView.swift` — depends on `TTSEngineSelector`
10. Modify `AudioViewModel.swift` — depends on `TTSEngineSelector`
11. Modify `ContentView.swift` — depends on `TTSMetricsView`
