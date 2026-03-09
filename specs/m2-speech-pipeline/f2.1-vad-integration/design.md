# F2.1: VAD Integration — Technical Design

**Feature**: Voice Activity Detection Integration
**Milestone**: M2 — Speech Pipeline
**Status**: DRAFT — awaiting Gate 2 review
**Date**: 2026-03-07
**Prerequisites**: requirements.md (Gate 1 approved)

---

## 1. Key Design Decisions

### 1.1 `SpeechSegment` carries `AVAudioPCMBuffer`, not `[Float]`

> Cupertino finding: `SFSpeechAudioBufferRecognitionRequest.append(_:)` takes `AVAudioPCMBuffer` directly.

Yielding `AVAudioPCMBuffer` from VAD means F2.2 (STT) can append utterances to the recognition request without a conversion step. The buffer format (16 kHz mono Float32) is already valid for Apple Speech. `AVAudioPCMBuffer` has `@unchecked Sendable` declared in `AudioManager.swift` and is safe to pass across actor boundaries.

VAD accumulates samples internally as `[Float]` (append is O(1) amortized), then wraps into a single `AVAudioPCMBuffer` at utterance end.

### 1.2 VAD is a standalone actor — not owned by AudioManager

`VADService` is an independent actor that subscribes to `AudioManager.audioStream16kHz`. AudioManager stays focused on capture/routing. VAD can be started/stopped independently and is easier to unit-test without running the real audio engine.

### 1.3 Engine selection via factory + silent fallback

`VADServiceFactory` tries to init `SileroVADService` first. If the model download fails (no internet on first launch), it falls back to `EnergyVADService` immediately and starts a background `Task` to retry the Silero download. When the download completes, the factory notifies the ViewModel to switch engines on next capture start.

### 1.4 `VADConfiguration` wraps FluidAudio types

Our public API exposes `VADConfiguration` (our struct) rather than `VadConfig`/`VadSegmentationConfig`. This insulates call sites from FluidAudio API changes and keeps our module boundary clean.

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         @MainActor                                  │
│                                                                     │
│  AudioViewModel                                                     │
│  ├── audioManager: AudioManager          ─────────────────────────┐ │
│  ├── vadService: any VADService                                    │ │
│  └── @Published isSpeechActive: Bool ◀─────────────────────┐     │ │
└───────────────────────────────────────────────────────────────│───┘ │
                                                               │      │
                    actor                                      │      │
┌──────────────────────────────────┐   AsyncStream<Bool>      │      │
│  SileroVADService / EnergyVAD    │──(vadStateEvents)────────┘      │
│                                  │                                  │
│  ▸ Task: buffer loop             │◀─── audioStream16kHz ───────────┘
│  ▸ [Float] accumulator           │     AsyncStream<AVAudioPCMBuffer>
│  ▸ VadStreamState                │
│  ▸ speechSegments continuation   │──── AsyncStream<SpeechSegment> ──▶ F2.2 STT
└──────────────────────────────────┘
```

---

## 3. Type Definitions

### 3.1 `SpeechSegment`

```swift
/// A complete detected utterance, ready for STT.
struct SpeechSegment: Sendable {
    /// 16 kHz mono Float32 — matches AudioManager.audioStream16kHz format.
    /// Appendable directly to SFSpeechAudioBufferRecognitionRequest.
    let audio: AVAudioPCMBuffer
    /// Wall-clock timestamp when speech started (for logging/latency measurement).
    let capturedAt: Date
}
```

`AVAudioPCMBuffer` is `@unchecked Sendable` via the extension in `AudioManager.swift` (already in codebase).

### 3.2 `VADConfiguration`

```swift
struct VADConfiguration: Sendable {
    /// Speech probability threshold. Above this → speech active. (Silero only)
    var sileroThreshold: Float = 0.85
    /// RMS level threshold in dBFS. Above this → speech active. (Energy only)
    var energyThresholdDBFS: Float = -40.0
    /// Minimum speech duration to yield a segment.
    var minSpeechDuration: TimeInterval = 0.15
    /// Minimum silence duration to close a segment.
    var minSilenceDuration: TimeInterval = 0.75
    /// Maximum utterance duration before forced emit.
    var maxSpeechDuration: TimeInterval = 14.0
    /// Context padding added before speech start boundary.
    var speechPadding: TimeInterval = 0.1

    static let `default` = VADConfiguration()

    // MARK: - Derived FluidAudio types (internal)
    internal var fluidVadConfig: VadConfig {
        VadConfig(defaultThreshold: sileroThreshold)
    }
    internal var fluidSegmentationConfig: VadSegmentationConfig {
        VadSegmentationConfig(
            minSpeechDuration: minSpeechDuration,
            minSilenceDuration: minSilenceDuration,
            maxSpeechDuration: maxSpeechDuration,
            speechPadding: speechPadding
        )
    }
}
```

### 3.3 `VADEngine` and `VADService` protocol

```swift
enum VADEngine: Sendable {
    case silero
    case energy
}

/// Actor protocol — both implementations are actors.
/// Callers use `await` for isolated methods; streams are nonisolated (set in init).
protocol VADService: Actor {
    /// Completed utterances, ready for STT. Initialized in init(), nonisolated.
    nonisolated var speechSegments: AsyncStream<SpeechSegment> { get }
    /// Bool events: true = speech started, false = speech ended.
    nonisolated var vadStateEvents: AsyncStream<Bool> { get }
    /// Currently active engine.
    nonisolated var engine: VADEngine { get }

    /// Begin consuming the given 16 kHz stream. Spawns internal processing Task.
    func activate(stream: AsyncStream<AVAudioPCMBuffer>) async throws
    /// Stop processing. Yields final segment if enough speech was buffered.
    func deactivate() async
}
```

`nonisolated var speechSegments` is possible because `AsyncStream` is a value type with no actor isolation itself — we initialize it in `init()` (same pattern as AudioManager's lazy streams, but without the lazy wrapper since actors don't need @MainActor isolation tricks).

---

## 4. SileroVADService — Implementation Design

### 4.1 Initialization

```swift
actor SileroVADService: VADService {
    nonisolated let speechSegments: AsyncStream<SpeechSegment>
    nonisolated let vadStateEvents: AsyncStream<Bool>
    nonisolated let engine: VADEngine = .silero

    private let config: VADConfiguration
    private let vadManager: VadManager            // FluidAudio actor

    // Continuations (set in init, used in processing task — actor-isolated)
    private var segmentContinuation: AsyncStream<SpeechSegment>.Continuation?
    private var stateContinuation: AsyncStream<Bool>.Continuation?

    // Processing state (actor-isolated)
    private var processingTask: Task<Void, Never>?
    private var sampleAccumulator: [Float] = []      // incoming 16kHz samples
    private var utteranceBuffer: [Float] = []         // samples since speechStart
    private var vadStreamState: VadStreamState = .initial()
    private var utteranceStartDate: Date?

    init(config: VADConfiguration = .default) async throws {
        self.config = config

        // Set up streams before spawning any tasks (same pattern as AudioManager)
        var segCont: AsyncStream<SpeechSegment>.Continuation?
        var stateCont: AsyncStream<Bool>.Continuation?
        speechSegments = AsyncStream { segCont = $0 }
        vadStateEvents = AsyncStream { stateCont = $0 }

        // These are assigned before any await — safe for nonisolated access
        segmentContinuation = segCont
        stateContinuation = stateCont

        // VadManager is an actor — init is async throws
        vadManager = try await VadManager(config: config.fluidVadConfig)
    }
}
```

**Note on `nonisolated var` with continuations**: The continuations are stored as actor-isolated `var` properties. The `speechSegments` and `vadStateEvents` streams are value-type copies initialized in `init()` — they can be `nonisolated let` because `AsyncStream` is `Sendable` and the value is set once.

### 4.2 Activation and Processing Loop

```swift
extension SileroVADService {
    func activate(stream: AsyncStream<AVAudioPCMBuffer>) async throws {
        guard processingTask == nil else { return }

        // Reset state for fresh capture session
        sampleAccumulator = []
        utteranceBuffer = []
        vadStreamState = await vadManager.makeStreamState()

        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.runProcessingLoop(stream: stream)
        }
    }

    func deactivate() async {
        processingTask?.cancel()
        processingTask = nil
        await flushUtteranceIfNeeded()
    }

    // MARK: - Internal

    private func runProcessingLoop(stream: AsyncStream<AVAudioPCMBuffer>) async {
        for await buffer in stream {
            guard !Task.isCancelled else { break }
            await appendBuffer(buffer)
        }
        await flushUtteranceIfNeeded()
    }

    private func appendBuffer(_ buffer: AVAudioPCMBuffer) async {
        // Extract Float32 samples from the buffer
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
        sampleAccumulator.append(contentsOf: samples)

        // Process all complete 4096-sample chunks
        while sampleAccumulator.count >= VadManager.chunkSize {
            let chunk = Array(sampleAccumulator.prefix(VadManager.chunkSize))
            sampleAccumulator.removeFirst(VadManager.chunkSize)
            await processChunk(chunk)
        }
    }

    private func processChunk(_ chunk: [Float]) async {
        // If speech is active, buffer all incoming samples
        if vadStreamState.triggered {
            utteranceBuffer.append(contentsOf: chunk)

            // Force-emit if max duration exceeded
            let maxSamples = Int(config.maxSpeechDuration * Double(VadManager.sampleRate))
            if utteranceBuffer.count >= maxSamples {
                await yieldUtterance()
                vadStreamState = await vadManager.makeStreamState()  // reset VAD state
                return
            }
        }

        // Run Silero VAD on this chunk
        let result: VadStreamResult
        do {
            result = try await vadManager.processStreamingChunk(
                chunk,
                state: vadStreamState,
                config: config.fluidSegmentationConfig
            )
        } catch {
            // Model error — silently skip chunk, keep state unchanged
            return
        }

        vadStreamState = result.state

        // Handle state transitions
        if let event = result.event {
            switch event.kind {
            case .speechStart:
                utteranceStartDate = Date()
                // Start buffering from the sample indicated by event (pre-start context)
                let contextStart = max(0, event.sampleIndex)
                _ = contextStart  // Used in full implementation to prepend context from accumulator history
                utteranceBuffer = chunk  // Simplified: start from current chunk
                await publishVADState(true)

            case .speechEnd:
                await yieldUtterance()
                utteranceBuffer = []
                utteranceStartDate = nil
                await publishVADState(false)
            }
        } else if vadStreamState.triggered && !utteranceBuffer.isEmpty {
            // Mid-speech chunk: keep buffering (already done above before VAD call)
        } else if !vadStreamState.triggered && utteranceBuffer.isEmpty {
            // Silence — nothing to buffer
        }
    }

    private func yieldUtterance() async {
        guard utteranceBuffer.count >= Int(config.minSpeechDuration * Double(VadManager.sampleRate)) else {
            utteranceBuffer = []
            return
        }
        guard let pcmBuffer = makePCMBuffer(from: utteranceBuffer) else {
            utteranceBuffer = []
            return
        }
        let segment = SpeechSegment(audio: pcmBuffer, capturedAt: utteranceStartDate ?? Date())
        segmentContinuation?.yield(segment)
        utteranceBuffer = []
    }

    private func flushUtteranceIfNeeded() async {
        if vadStreamState.triggered {
            await yieldUtterance()
        }
    }

    private func publishVADState(_ active: Bool) async {
        stateContinuation?.yield(active)
    }

    private func makePCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(VadManager.sampleRate),
            channels: 1,
            interleaved: false
        ) else { return nil }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData?[0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
```

### 4.3 Buffer Accumulation Math

- AudioManager tap: 1024 frames @ 48 kHz → downsampled to ~341 frames @ 16 kHz per callback
- Silero chunk: 4096 samples = 256 ms @ 16 kHz
- Callbacks per VAD inference: 4096 / 341 ≈ **12 callbacks**
- VAD latency per utterance boundary: ≤ 2 × 256 ms = **512 ms** (two chunks for hysteresis)

---

## 5. EnergyVADService — Implementation Design

```swift
actor EnergyVADService: VADService {
    nonisolated let speechSegments: AsyncStream<SpeechSegment>
    nonisolated let vadStateEvents: AsyncStream<Bool>
    nonisolated let engine: VADEngine = .energy

    private let config: VADConfiguration
    private var segmentContinuation: AsyncStream<SpeechSegment>.Continuation?
    private var stateContinuation: AsyncStream<Bool>.Continuation?
    private var processingTask: Task<Void, Never>?

    // State machine
    private enum State { case silence, speaking }
    private var state: State = .silence
    private var utteranceBuffer: [Float] = []
    private var silenceSampleCount: Int = 0
    private var utteranceStartDate: Date?

    init(config: VADConfiguration = .default) {
        self.config = config
        var segCont: AsyncStream<SpeechSegment>.Continuation?
        var stateCont: AsyncStream<Bool>.Continuation?
        speechSegments = AsyncStream { segCont = $0 }
        vadStateEvents = AsyncStream { stateCont = $0 }
        segmentContinuation = segCont
        stateContinuation = stateCont
    }

    func activate(stream: AsyncStream<AVAudioPCMBuffer>) async throws {
        guard processingTask == nil else { return }
        state = .silence
        utteranceBuffer = []
        processingTask = Task { [weak self] in
            guard let self else { return }
            for await buffer in stream {
                guard !Task.isCancelled else { break }
                await self.processBuffer(buffer)
            }
            await self.flush()
        }
    }

    func deactivate() async {
        processingTask?.cancel()
        processingTask = nil
        await flush()
    }
}
```

Energy VAD uses vDSP `vDSP_measqv` (already used in `AudioManager.computeRMS`) to compute RMS per buffer, compares against `energyThresholdDBFS`, then applies the same min-speech / min-silence windowing logic (sample count based).

---

## 6. VADServiceFactory

```swift
/// Creates and manages the active VADService instance.
/// Tries Silero first; falls back to Energy if model unavailable.
@MainActor
final class VADServiceFactory: ObservableObject {
    @Published private(set) var activeEngine: VADEngine = .energy
    @Published private(set) var sileroModelAvailable: Bool = false

    private(set) var service: any VADService

    /// Synchronously available fallback (no async init needed)
    private let energyService: EnergyVADService

    init(config: VADConfiguration = .default) {
        energyService = EnergyVADService(config: config)
        service = energyService
        activeEngine = .energy

        // Attempt Silero init in background
        Task { [weak self] in
            await self?.tryLoadSilero(config: config)
        }
    }

    private func tryLoadSilero(config: VADConfiguration) async {
        do {
            let silero = try await SileroVADService(config: config)
            service = silero
            activeEngine = .silero
            sileroModelAvailable = true
        } catch {
            // Model not available — stay on energy VAD
            sileroModelAvailable = false
        }
    }
}
```

**Why `@MainActor`?** `VADServiceFactory` is an `ObservableObject` observed by `AudioViewModel`, which already lives on `@MainActor`. The actual VAD work runs inside the actor implementations, not on `@MainActor`.

---

## 7. AudioViewModel Integration

```swift
// In AudioViewModel (existing @MainActor ObservableObject)

@Published var isSpeechActive: Bool = false

private var vadStateTask: Task<Void, Never>?

func onVADServiceReady(_ service: any VADService) {
    vadStateTask?.cancel()
    vadStateTask = Task { @MainActor [weak self] in
        for await active in service.vadStateEvents {
            self?.isSpeechActive = active
        }
    }
}
```

`speechSegments` is consumed by the STT layer (F2.2), not by the ViewModel.

---

## 8. File Structure

```
TranslateCall/
└── Core/
    └── VAD/
        ├── VADService.swift          // protocol + SpeechSegment + VADConfiguration + VADEngine
        ├── SileroVADService.swift    // FluidAudio Silero implementation
        ├── EnergyVADService.swift    // Energy-based fallback
        └── VADServiceFactory.swift   // @MainActor factory + engine lifecycle

TranslateCallTests/
└── VADServiceTests.swift             // AC-01 through AC-10
```

---

## 9. Threading and Swift 6 Compliance

| Concern | Solution |
|---------|---------|
| VAD inference (Silero) blocks | Runs inside actor's `async` method; `VadManager` is itself an actor — no deadlock |
| Buffer mutations | All in actor-isolated `processChunk`/`appendBuffer` — no data races |
| `AVAudioPCMBuffer` across actors | `@unchecked Sendable` extension already in codebase |
| UI `isSpeechActive` updates | Dispatched through `AsyncStream<Bool>` iterated on `@MainActor` |
| `nonisolated let` streams | Set once in `init()` before any async work — safe |
| `VadStreamState` | `Sendable` value type — no conformance boilerplate needed |

---

## 10. Error Handling

| Error | Behavior |
|-------|---------|
| Silero model download fails | Factory silently uses `EnergyVADService`; retries on next app launch |
| `VadManager.processStreamingChunk` throws | Chunk is skipped; `vadStreamState` unchanged; processing continues |
| `AVAudioPCMBuffer` allocation fails | Utterance discarded; buffer cleared; logging via `os_log` |
| `processingTask` cancelled mid-utterance | `deactivate()` calls `flushUtteranceIfNeeded()` before exit |

---

## 11. Pre-Speech Context Buffer (REQUIRED)

When `speechStart` fires, `VadStreamEvent.sampleIndex` points ~`speechPadding` (100ms = 1600 samples) **before** the current chunk. Without a history buffer, those samples are already gone — STT would miss the first syllable.

**Solution**: maintain a fixed-size circular history buffer of the last `speechPadding + 1 chunk` = ~1600 + 4096 = ~5700 samples (~360ms) of incoming 16kHz audio. When `speechStart` fires, prepend the relevant tail of the history to `utteranceBuffer` before continuing to accumulate.

```
historyBuffer (ring, ~5700 samples, always rolling):
  [...old...][pre-context 1600 samples][current chunk 4096]
                        ↑
              prepended to utteranceBuffer on speechStart

utteranceBuffer after prepend:
  [pre-context 1600][chunk₀ 4096][chunk₁ 4096]...
```

This adds ~32 KB of memory (5700 × 4 bytes × 1.5 safety margin) and zero latency overhead. It is **mandatory** — without it STT accuracy degrades on the first syllable of every utterance.

---

*Gate 2 Review: human must approve this document before tasks.md is written.*
