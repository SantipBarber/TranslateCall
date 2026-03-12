# F6.2 — MLX-Audio Kokoro TTS: Task Breakdown

> **Feature**: F6.2 — MLX-Audio Kokoro TTS Integration
> **Milestone**: M6 — Enhanced STT/TTS
> **Status**: DRAFT
> **Depends on**: design.md (approved)
> **Date**: 2026-03-12

---

## Overview

9 tasks in dependency order. T0 is a spike (read FluidAudio source, resolve open questions) and must complete before any implementation. Each subsequent task follows a TDD cycle (RED → GREEN → REFACTOR).

```
T0 (spike/package) ──▶ T1 (shared types) ──▶ T2 (metrics collector)
                                │
                                ▼
                        T3 (model manager) ──▶ T4 (service) ──▶ T5 (selector)
                                                                      │
                                                      T6 (coordinator/viewmodel) ◀─┘
                                                      T7 (UI)         ◀── T5, T6
                                                      T8 (integration) ◀── T0–T7
```

---

## T0 — Spike: FluidAudio TTS API + Package Bump

**Covers**: OQ-1 through OQ-5 from design.md § 10; REQ-KOK-NF-09 (protocol compatibility check)

**Files to modify**:
- `TranslateCall.xcodeproj/project.pbxproj` — bump FluidAudio to ≥ 0.12.3, add `FluidAudioTTS` product

### Steps

1. **Read FluidAudio source** — in `~/.swiftpm/` or via `File > Packages > Update` in Xcode, browse the `FluidAudioTTS` target. Specifically locate and read:
   - `KokoroTtsManager` class — answer OQ-1 (is `synthesize` truly `async throws -> Data`?), OQ-4 (is it `Sendable`?)
   - `VariantPreference` type — answer OQ-2 (what values exist? does it control voice?)
   - `initialize()` — answer OQ-3 (does it auto-download or require pre-cached model?)
   - WAV output — answer OQ-5 (44-byte header? extended header?)

2. **Document answers** inline in this file below each OQ (update before proceeding to T1).

3. **Add `FluidAudioTTS` product** to the main target in Xcode (alongside the existing `FluidAudio` product for Parakeet):
   - Bump version requirement: `from: "0.12.3"` (or `upToNextMajor: "0.12.3"`)
   - Target → Build Phases → Link Binary With Libraries → add `FluidAudioTTS.framework`

4. **Verify build**: Add `import FluidAudioTTS` in a scratch file; confirm `KokoroTtsManager` resolves.

5. **Define `KokoroTtsManaging` protocol** (minimal surface for test injection):
   ```swift
   // Core/TTS/KokoroTtsManaging.swift (NEW)
   protocol KokoroTtsManaging: Sendable {
       func synthesize(text: String) async throws -> Data
       // Add voice/variant methods if OQ-2 reveals them
   }
   extension KokoroTtsManager: KokoroTtsManaging {}
   ```
   If `KokoroTtsManager` is not `Sendable`, use `@unchecked @retroactive Sendable` (same pattern as `SCRunningApplication` in F4.3).

### OQ Answers (resolved)

- **OQ-1** (`synthesize` async?): YES — `synthesize(text:voice:voiceSpeed:speakerId:variantPreference:deEss:) async throws -> Data`. Also `synthesizeDetailed(...)` returns `KokoroSynthesizer.SynthesisResult`.
- **OQ-2** (voice selection via `VariantPreference`?): `variantPreference: ModelNames.TTS.Variant?` controls segment *length* (`.fiveSecond` / `.fifteenSecond`), NOT voice. Voice is selected via `voice: String?` (e.g. `"af_heart"`, `"am_adam"`). Full voice list in `TtsConstants.availableVoices` (54 voices across 8 languages).
- **OQ-3** (auto-download on `initialize()`?): YES — `initialize()` calls `TtsModels.download(directory:)` which downloads from HuggingFace `FluidInference/kokoro-82m-coreml` and caches at `~/.cache/fluidaudio/Models/kokoro/`.
- **OQ-4** (`KokoroTtsManager: Sendable`?): NO — `public final class`, no Sendable. Fixed with `extension KokoroTtsManager: @unchecked @retroactive Sendable {}` in `KokoroTtsManaging.swift`.
- **OQ-5** (WAV format?): **Bypassed entirely** — `synthesizeDetailed().chunks[n].samples` contains raw `[Float]` at 24 kHz. `KokoroTtsManaging.synthesizeSamples()` uses this path directly. No WAV parsing, no temp files, no AVAudioConverter needed for decode (only SRC 24kHz→device rate).

### Acceptance

- Project builds with `import FluidAudioTTS` in one file.
- All 5 OQs answered; design.md § 10 updated if answers require design changes.
- `KokoroTtsManaging` protocol defined and compiles.

---

## T1 — Shared Types

**Covers**: REQ-KOK-20, REQ-KOK-21, REQ-KOK-NF-09, REQ-KOK-NF-10

**Files to create**:
- `Core/TTS/TTSEngine.swift` (NEW)
- `Core/TTS/TTSMetrics.swift` (NEW)
- `Core/TTS/KokoroConfiguration.swift` (NEW)

### Steps

1. **`TTSEngine.swift`**:
   ```swift
   enum TTSEngine: String, Codable, Sendable, CaseIterable {
       case avSpeech
       case kokoro

       var displayName: String { … }
       func supports(locale: Locale) -> Bool { … }
   }
   ```
   - `avSpeech.supports` → always `true`
   - `kokoro.supports` → `locale.isEnglish` (reuse the extension already in `STTEngine.swift`)

2. **`TTSMetrics.swift`**:
   ```swift
   struct TTSMetrics: Sendable {
       let engine: TTSEngine
       let synthesisLatencyMs: Int
       let textLength: Int
       let locale: Locale
       let timestamp: Date
   }

   struct TTSMetricsSummary: Sendable {
       let avgLatencyMs: Double
       let count: Int
       nonisolated(unsafe) static let empty = TTSMetricsSummary(avgLatencyMs: 0, count: 0)
   }
   ```

3. **`KokoroConfiguration.swift`**:
   ```swift
   struct KokoroConfiguration: Sendable {
       var voiceIdentifier: String = ""
       var modelVersion: String = "v1"
       static let voiceDefaultsKey = "tlk.tts.kokoro.voice"
       nonisolated(unsafe) static let `default` = KokoroConfiguration()
   }
   ```
   - If OQ-2 reveals a `VariantPreference` enum, add `var variantPreference: VariantPreference` here.

### Tests (RED first)

```swift
// TranslateCallTests/TTSEngineTests.swift
@Suite @MainActor struct TTSEngineTests {

    @Test func avSpeechSupportsAllLocales() {
        #expect(TTSEngine.avSpeech.supports(locale: Locale(identifier: "ja-JP")))
        #expect(TTSEngine.avSpeech.supports(locale: Locale(identifier: "fr-FR")))
    }

    @Test func kokoroSupportsEnglish() {
        #expect(TTSEngine.kokoro.supports(locale: Locale(identifier: "en-US")))
        #expect(TTSEngine.kokoro.supports(locale: Locale(identifier: "en-GB")))
    }

    @Test func kokoroRejectsNonEnglish() {
        #expect(!TTSEngine.kokoro.supports(locale: Locale(identifier: "es-ES")))
        #expect(!TTSEngine.kokoro.supports(locale: Locale(identifier: "zh-Hans")))
    }

    @Test func rawValueRoundTrip() {
        #expect(TTSEngine(rawValue: "kokoro") == .kokoro)
        #expect(TTSEngine(rawValue: "avSpeech") == .avSpeech)
    }

    @Test func displayNameNonEmpty() {
        for engine in TTSEngine.allCases {
            #expect(!engine.displayName.isEmpty)
        }
    }
}
```

**Acceptance**: 5 tests pass. `TTSEngine` is Codable.

---

## T2 — `TTSMetricsCollector`

**Covers**: REQ-KOK-24 through REQ-KOK-26

**Files to create**:
- `Core/TTS/TTSMetricsCollector.swift` (NEW)

### Steps

1. Declare `actor TTSMetricsCollector` with `static let shared`.
2. `private var recent: [TTSMetrics] = []` capped at 100 entries (same cap as `STTMetricsCollector`).
3. `func record(_ metrics: TTSMetrics)` — append, trim oldest if over cap.
4. `func summary(for engine: TTSEngine) -> TTSMetricsSummary`:
   - Filter by engine; compute `avgLatencyMs`; return `.empty` for empty.
5. `func reset()` — clears all entries (used in tests).

### Tests

```swift
// TranslateCallTests/TTSMetricsCollectorTests.swift
@Suite @MainActor struct TTSMetricsCollectorTests {

    let collector = TTSMetricsCollector()  // fresh instance per suite (not .shared)

    private func metric(_ engine: TTSEngine, latency: Int) -> TTSMetrics {
        TTSMetrics(engine: engine, synthesisLatencyMs: latency, textLength: 10,
                   locale: Locale(identifier: "en-US"), timestamp: .now)
    }

    @Test func recordAndSummary() async {
        await collector.record(metric(.kokoro, latency: 400))
        await collector.record(metric(.kokoro, latency: 600))
        let summary = await collector.summary(for: .kokoro)
        #expect(summary.avgLatencyMs == 500.0)
        #expect(summary.count == 2)
    }

    @Test func engineFilteringInSummary() async {
        await collector.record(metric(.kokoro, latency: 400))
        await collector.record(metric(.avSpeech, latency: 120))
        let kokoroSummary = await collector.summary(for: .kokoro)
        let avSummary = await collector.summary(for: .avSpeech)
        #expect(kokoroSummary.count == 1)
        #expect(avSummary.count == 1)
    }

    @Test func capsAtOneHundred() async {
        for i in 0..<110 {
            await collector.record(metric(.avSpeech, latency: i))
        }
        let count = await collector.recent.count
        #expect(count == 100)
    }

    @Test func dropsOldestOnOverflow() async {
        for i in 0..<101 {
            await collector.record(metric(.kokoro, latency: i))
        }
        // The oldest entry (latency=0) must be gone; newest (latency=100) must be present
        let summary = await collector.summary(for: .kokoro)
        #expect(summary.count == 100)
        // avgLatencyMs of entries 1..100 = 50.5
        #expect(abs(summary.avgLatencyMs - 50.5) < 0.1)
    }

    @Test func summaryForUnseenEngineReturnsEmpty() async {
        let summary = await collector.summary(for: .kokoro)
        #expect(summary == TTSMetricsSummary.empty)
    }

    @Test func resetClearsAllEntries() async {
        await collector.record(metric(.kokoro, latency: 300))
        await collector.reset()
        let summary = await collector.summary(for: .kokoro)
        #expect(summary.count == 0)
    }
}
```

Make `TTSMetricsSummary` conform to `Equatable` to enable `#expect(summary == .empty)`.

**Acceptance**: 6 tests pass.

---

## T3 — `KokoroModelManager`

**Covers**: REQ-KOK-01 through REQ-KOK-07, REQ-KOK-NF-02, REQ-KOK-NF-03, REQ-KOK-NF-04

**Files to create**:
- `Core/TTS/KokoroModelManager.swift` (NEW)

### Steps

1. Declare `actor KokoroModelManager` with `static let shared = KokoroModelManager()`.

2. State machine:
   ```swift
   enum ModelState: Sendable {
       case idle
       case loading
       case ready(any KokoroTtsManaging)
       case failed(String)
   }
   ```

3. `let stateStream: AsyncStream<ModelState>` + private `stateContinuation`.

4. `typealias ManagerFactory = @Sendable (KokoroConfiguration) async throws -> any KokoroTtsManaging`
   - `nonisolated(unsafe) static let defaultFactory: ManagerFactory` — calls `KokoroTtsManager()` + `initialize()`
   - Adjust based on OQ-3: if `initialize()` auto-downloads, `defaultFactory` is simply `{ _ in let m = KokoroTtsManager(); try await m.initialize(); return m }`. If it requires pre-cached files, add a download step before `initialize()`.

5. `func ensureReady(config: KokoroConfiguration = .default) async throws -> any KokoroTtsManaging`:
   - Fast path: `.ready(mgr)` → return `mgr`
   - Coalesce: if `loadTask != nil`, `return try await loadTask!.value`
   - Otherwise: `startLoading(config:)`

6. `func unload()`:
   - Cancel `loadTask`; set `loadTask = nil`; transition to `.idle`

7. `func redownload(config:) async throws -> any KokoroTtsManaging`:
   - `unload()` then `startLoading(config:)`

8. Private `startLoading(config:)` — same pattern as `ParakeetModelManager`.

### Tests

```swift
// TranslateCallTests/KokoroModelManagerTests.swift
@Suite @MainActor struct KokoroModelManagerTests {

    // Helper: manager with injectable factory
    func makeManager(factory: KokoroModelManager.ManagerFactory) -> KokoroModelManager {
        KokoroModelManager(managerFactory: factory)
    }

    @Test func initialStateIsIdle() async {
        let mgr = makeManager(factory: { _ in fatalError("should not be called") })
        if case .idle = await mgr.state { } else { Issue.record("expected .idle") }
    }

    @Test func ensureReadyTransitionsToReady() async throws {
        let stub = MockKokoroTtsManager()
        let mgr = makeManager(factory: { _ in stub })
        let result = try await mgr.ensureReady()
        if case .ready = await mgr.state { } else { Issue.record("expected .ready") }
        _ = result  // verifies no throw
    }

    @Test func ensureReadySetsFailedOnError() async {
        struct FakeError: Error {}
        let mgr = makeManager(factory: { _ in throw FakeError() })
        do { _ = try await mgr.ensureReady() } catch {}
        if case .failed = await mgr.state { } else { Issue.record("expected .failed") }
    }

    @Test func concurrentCallersCoalesce() async throws {
        var callCount = 0
        let stub = MockKokoroTtsManager()
        let mgr = makeManager(factory: { _ in
            callCount += 1
            try await Task.sleep(for: .milliseconds(50))
            return stub
        })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = try await mgr.ensureReady() } }
            try await group.waitForAll()
        }
        #expect(callCount == 1)
    }

    @Test func unloadResetsToIdle() async throws {
        let stub = MockKokoroTtsManager()
        let mgr = makeManager(factory: { _ in stub })
        _ = try await mgr.ensureReady()
        await mgr.unload()
        if case .idle = await mgr.state { } else { Issue.record("expected .idle after unload") }
    }

    @Test func redownloadReloadsModel() async throws {
        var callCount = 0
        let stub = MockKokoroTtsManager()
        let mgr = makeManager(factory: { _ in callCount += 1; return stub })
        _ = try await mgr.ensureReady()  // callCount = 1
        _ = try await mgr.redownload()   // callCount = 2
        #expect(callCount == 2)
    }

    @Test func stateStreamEmitsTransitions() async throws {
        let stub = MockKokoroTtsManager()
        let mgr = makeManager(factory: { _ in stub })
        var states: [KokoroModelManager.ModelState] = []
        let task = Task { for await s in mgr.stateStream { states.append(s) } }
        _ = try await mgr.ensureReady()
        await mgr.unload()
        task.cancel()
        // Must have seen .loading then .ready then .idle
        let hasLoading = states.contains { if case .loading = $0 { return true }; return false }
        let hasReady   = states.contains { if case .ready   = $0 { return true }; return false }
        #expect(hasLoading && hasReady)
    }
}
```

Define `MockKokoroTtsManager` in `TranslateCallTests/Mocks/MockKokoroTtsManager.swift`:
```swift
final class MockKokoroTtsManager: KokoroTtsManaging, @unchecked Sendable {
    var stubData: Data = Data(repeating: 0, count: 44 + 100)  // minimal WAV
    var stubError: Error?
    private(set) var callCount = 0

    func synthesize(text: String) async throws -> Data {
        callCount += 1
        if let error = stubError { throw error }
        return stubData
    }
}
```

**Acceptance**: 7 tests pass without real FluidAudio model download.

---

## T4 — `KokoroSpeechService`

**Covers**: REQ-KOK-08 through REQ-KOK-12, REQ-KOK-NF-01, REQ-KOK-NF-05 through REQ-KOK-NF-08, REQ-KOK-NF-09

**Files to create**:
- `Core/TTS/KokoroSpeechService.swift` (NEW)

### Steps

1. Declare `actor KokoroSpeechService: SynthesisService`.

2. `nonisolated let isSpeakingStream: AsyncStream<Bool>` + private continuation.

3. `init(outputDeviceID: AudioDeviceID?, configuration: KokoroConfiguration = .default, modelManager: KokoroModelManager = .shared) throws` — call `setupAudioEngine()`.

4. **`setupAudioEngine()`**: `playerNode → mixer (nil format) → outputNode (hardware format)` — identical graph to `AVSpeechService`. Call `engine.start()` or throw `STSError.engineStartFailed`.

5. **`speak(text:locale:) async`**:
   - Guard non-empty text (REQ-KOK-NF-06): return silently if blank.
   - Append to `pendingTexts: [(String, Locale)]`.
   - If `!isSpeaking`, call `await processNext()`.

6. **`stopSpeaking() async`**:
   - Clear `pendingTexts`; `playerNode.stop()`; `setSpeaking(false)`.

7. **`deactivate() async`**:
   - `await stopSpeaking()`; `engine.stop()`.

8. **`processNext() async`** (private):
   - Pop `pendingTexts.first`; guard not empty else `setSpeaking(false); return`.
   - `setSpeaking(true)`.
   - Measure `startDate`.
   - `let manager = try await modelManager.ensureReady(config: configuration)`.
   - Handle long text (REQ-KOK-NF-07): if `text.count > 500`, truncate to last word boundary before 500 chars and log warning.
   - `let wavData = try await manager.synthesize(text: text)`.
   - `let latencyMs = Int(Date().timeIntervalSince(startDate) * 1000)`.
   - `guard let buffer = decodeWav(wavData) else { setSpeaking(false); await processNext(); return }`.
   - `scheduleBuffer(buffer)`.
   - Record `TTSMetrics` via `Task { await TTSMetricsCollector.shared.record(...) }`.
   - (Playback completion → `bufferCompleted()` → `await processNext()`).

9. **`decodeWav(_ data: Data) -> AVAudioPCMBuffer?`** (private):
   - Write `data` to a temp file via `FileManager.default.temporaryDirectory`.
   - Open with `AVAudioFile(forReading:)` to get the native format (avoids manual header parsing; handles both 44-byte and extended headers — resolves OQ-5).
   - Read all frames into a `kokoroBuf` (24 kHz Float32 mono).
   - If `outputFormat.sampleRate == 24_000`, return `kokoroBuf` directly.
   - Otherwise convert via `AVAudioConverter` callback API (same pattern as `AudioManager`).
   - Clean up temp file after read.

10. **Output device routing**: call `routeToDevice(_:)` using `AudioUnitSetProperty` if `outputDeviceID != nil` — copy pattern from `AVSpeechService`.

### Tests

```swift
// TranslateCallTests/KokoroSpeechServiceTests.swift
@Suite(.serialized) @MainActor struct KokoroSpeechServiceTests {

    // Inject a KokoroModelManager with MockKokoroTtsManager
    func makeService(stubData: Data = makeMinimalWav(), stubError: Error? = nil)
        throws -> (KokoroSpeechService, MockKokoroTtsManager)
    {
        let mock = MockKokoroTtsManager()
        mock.stubData = stubData
        mock.stubError = stubError
        let modelMgr = KokoroModelManager(managerFactory: { _ in mock })
        let svc = try KokoroSpeechService(outputDeviceID: nil, modelManager: modelMgr)
        return (svc, mock)
    }

    /// Minimal 24kHz mono WAV: 44-byte header + 480 samples (10ms) of silence.
    static func makeMinimalWav() -> Data {
        let numSamples = 480
        let dataSize = numSamples * 2  // Int16
        var wav = Data(count: 44 + dataSize)
        wav.withUnsafeMutableBytes { ptr in
            let b = ptr.baseAddress!
            // RIFF header (enough for AVAudioFile to parse)
            b.copyMemory(from: "RIFF", byteCount: 4)
            (b + 4).storeBytes(of: UInt32(36 + dataSize).littleEndian, as: UInt32.self)
            (b + 8).copyMemory(from: "WAVEfmt ", byteCount: 8)
            (b + 16).storeBytes(of: UInt32(16).littleEndian, as: UInt32.self)  // chunk size
            (b + 20).storeBytes(of: UInt16(1).littleEndian, as: UInt16.self)   // PCM
            (b + 22).storeBytes(of: UInt16(1).littleEndian, as: UInt16.self)   // channels
            (b + 24).storeBytes(of: UInt32(24000).littleEndian, as: UInt32.self) // sample rate
            (b + 28).storeBytes(of: UInt32(48000).littleEndian, as: UInt32.self) // byte rate
            (b + 32).storeBytes(of: UInt16(2).littleEndian, as: UInt16.self)   // block align
            (b + 34).storeBytes(of: UInt16(16).littleEndian, as: UInt16.self)  // bits per sample
            (b + 36).copyMemory(from: "data", byteCount: 4)
            (b + 40).storeBytes(of: UInt32(dataSize).littleEndian, as: UInt32.self)
            // samples: zeroes (silence)
        }
        return wav
    }

    @Test func speakCallsSynthesize() async throws {
        let (svc, mock) = try makeService()
        await svc.speak(text: "Hello world", locale: Locale(identifier: "en-US"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(mock.callCount >= 1)
    }

    @Test func emptyTextIsNotSynthesised() async throws {
        let (svc, mock) = try makeService()
        await svc.speak(text: "   ", locale: Locale(identifier: "en-US"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(mock.callCount == 0)
    }

    @Test func stopSpeakingClearsQueue() async throws {
        let (svc, _) = try makeService()
        await svc.speak(text: "First", locale: Locale(identifier: "en-US"))
        await svc.speak(text: "Second", locale: Locale(identifier: "en-US"))
        await svc.stopSpeaking()
        let pending = await svc.pendingTexts
        #expect(pending.isEmpty)
    }

    @Test func synthesisErrorDoesNotCrash() async throws {
        struct FakeError: Error {}
        let (svc, _) = try makeService(stubError: FakeError())
        // Should log error and recover gracefully
        await svc.speak(text: "Test", locale: Locale(identifier: "en-US"))
        try await Task.sleep(for: .milliseconds(200))
        // No crash = pass; verify isSpeakingStream emits false
    }

    @Test func isSpeakingStreamEmitsFalseAfterPlayback() async throws {
        let (svc, _) = try makeService()
        var states: [Bool] = []
        let task = Task {
            for await speaking in svc.isSpeakingStream { states.append(speaking) }
        }
        await svc.speak(text: "Hello", locale: Locale(identifier: "en-US"))
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        // Must have emitted true then false
        #expect(states.contains(true))
        #expect(states.last == false)
    }

    @Test func metricsAreRecordedAfterSynthesis() async throws {
        let collector = TTSMetricsCollector()
        // Inject collector if TTSMetricsCollector supports injection;
        // otherwise use .shared and reset before/after test.
        let (svc, _) = try makeService()
        await svc.speak(text: "Hello", locale: Locale(identifier: "en-US"))
        try await Task.sleep(for: .milliseconds(300))
        let summary = await TTSMetricsCollector.shared.summary(for: .kokoro)
        #expect(summary.count >= 1)
        await TTSMetricsCollector.shared.reset()  // cleanup
    }

    @Test func longTextIsTruncatedWithoutCrash() async throws {
        let longText = String(repeating: "word ", count: 120)  // > 500 chars
        let (svc, mock) = try makeService()
        await svc.speak(text: longText, locale: Locale(identifier: "en-US"))
        try await Task.sleep(for: .milliseconds(300))
        // synthesize was called with truncated text
        #expect(mock.callCount == 1)
        // Verify truncated text length ≤ 500
        #expect((mock.lastReceivedText ?? "").count <= 500)
    }
}
```

Extend `MockKokoroTtsManager` with `var lastReceivedText: String?` to enable the last assertion.

**Notes**:
- `@Suite(.serialized)` required — multiple `AVAudioEngine` instances conflict in parallel.
- `pendingTexts` must be `internal` (not `private`) for the `stopSpeaking` test to inspect state — or expose via a `var pendingCount: Int` helper.

**Acceptance**: 7 tests pass without real model download. No crash on error injection.

---

## T5 — `TTSEngineSelector`

**Covers**: REQ-KOK-13 through REQ-KOK-23

**Files to create**:
- `Core/TTS/TTSEngineSelector.swift` (NEW)

### Steps

1. Declare `@MainActor final class TTSEngineSelector: ObservableObject`.

2. `@Published` properties:
   - `private(set) var preferredEngine: TTSEngine = .avSpeech`
   - `private(set) var kokoroAvailable: Bool = false`
   - `private(set) var isDownloading: Bool = false`
   - `private(set) var currentTargetLocale: Locale = Locale.current`

3. `var usingFallback: Bool { preferredEngine == .kokoro && !currentTargetLocale.isEnglish }`

4. Injectable factories (for tests):
   ```swift
   var avSpeechFactory: (AudioDeviceID?) throws -> any SynthesisService
   var kokoroFactory: (AudioDeviceID?, KokoroConfiguration) throws -> any SynthesisService
   ```
   Defaults create real services.

5. `init(defaults: UserDefaults = .standard)`:
   - Load `preferredEngine` from `defaults["tlk.tts.engine"]`, fallback `.avSpeech`.
   - Start `observeModelManager()`.

6. `func setPreferredEngine(_ engine: TTSEngine)`:
   - Update + persist to `defaults["tlk.tts.engine"]`.

7. `func makeOutgoingService(for locale: Locale, deviceID: AudioDeviceID?) throws -> any SynthesisService`:
   - `currentTargetLocale = locale`
   - If `preferredEngine == .kokoro && kokoroAvailable && locale.isEnglish`:
     - Build `KokoroConfiguration` with voice from defaults.
     - Return `kokoroFactory(deviceID, config)`.
   - Otherwise: return `avSpeechFactory(deviceID)`.

8. `func makeIncomingService(for locale: Locale, deviceID: AudioDeviceID?) throws -> any SynthesisService`:
   - Always `avSpeechFactory(deviceID)` — Kokoro is not used for incoming.

9. `func downloadKokoroModel()`:
   - Set `isDownloading = true`.
   - `Task { _ = try? await KokoroModelManager.shared.ensureReady(); isDownloading = false }`.

10. `func unloadKokoroModel()`:
    - `KokoroModelManager.shared.unload()`.
    - `kokoroAvailable = false`.

11. `private func observeModelManager()`:
    - Background `Task` observing `KokoroModelManager.shared.stateStream`.
    - `.ready` → `kokoroAvailable = true`; `.failed` / `.idle` → `kokoroAvailable = false`.

12. For testing: `func setKokoroAvailableForTesting(_ value: Bool) { kokoroAvailable = value }`.

### Tests

```swift
// TranslateCallTests/TTSEngineSelectorTests.swift
@Suite @MainActor struct TTSEngineSelectorTests {

    // Fresh UserDefaults suite per test to avoid cross-test pollution
    func makeSelector(suite: String = UUID().uuidString) -> TTSEngineSelector {
        let defaults = UserDefaults(suiteName: suite)!
        return TTSEngineSelector(defaults: defaults)
    }

    @Test func defaultEngineIsAVSpeech() {
        let selector = makeSelector()
        #expect(selector.preferredEngine == .avSpeech)
    }

    @Test func persistsPreference() throws {
        let suite = UUID().uuidString
        let selector = makeSelector(suite: suite)
        selector.setPreferredEngine(.kokoro)
        let restored = makeSelector(suite: suite)
        #expect(restored.preferredEngine == .kokoro)
    }

    @Test func kokoroPreferenceEnglishUsesKokoroFactory() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)
        var kokroCalled = false
        selector.kokoroFactory = { _, _ in kokroCalled = true; return MockSynthesisService() }
        selector.avSpeechFactory = { _ in MockSynthesisService() }
        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(kokroCalled)
    }

    @Test func kokoroPreferenceNonEnglishUsesAVSpeech() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)
        var avCalled = false
        selector.avSpeechFactory = { _ in avCalled = true; return MockSynthesisService() }
        _ = try selector.makeOutgoingService(for: Locale(identifier: "fr-FR"), deviceID: nil)
        #expect(avCalled)
    }

    @Test func kokoroPreferenceUnavailableUsesAVSpeech() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(false)
        var avCalled = false
        selector.avSpeechFactory = { _ in avCalled = true; return MockSynthesisService() }
        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(avCalled)
    }

    @Test func incomingAlwaysUsesAVSpeech() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)
        var avCalled = false
        selector.avSpeechFactory = { _ in avCalled = true; return MockSynthesisService() }
        _ = try selector.makeIncomingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(avCalled)
    }

    @Test func usingFallbackTrueForNonEnglishKokoro() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)
        _ = try selector.makeOutgoingService(for: Locale(identifier: "de-DE"), deviceID: nil)
        #expect(selector.usingFallback)
    }

    @Test func usingFallbackFalseForEnglishKokoro() throws {
        let selector = makeSelector()
        selector.setPreferredEngine(.kokoro)
        selector.setKokoroAvailableForTesting(true)
        selector.avSpeechFactory = { _ in MockSynthesisService() }
        selector.kokoroFactory = { _, _ in MockSynthesisService() }
        _ = try selector.makeOutgoingService(for: Locale(identifier: "en-US"), deviceID: nil)
        #expect(!selector.usingFallback)
    }

    @Test func downloadKokoroModelSetsIsDownloading() async {
        let selector = makeSelector()
        selector.downloadKokoroModel()
        #expect(selector.isDownloading)
    }
}
```

Add `MockSynthesisService` to `TranslateCallTests/Mocks/`:
```swift
actor MockSynthesisService: SynthesisService {
    nonisolated let isSpeakingStream = AsyncStream<Bool> { $0.finish() }
    func speak(text: String, locale: Locale) async {}
    func stopSpeaking() async {}
    func deactivate() async {}
}
```

**Acceptance**: 8 tests pass.

---

## T6 — `AudioCoordinator` + `AudioViewModel` Integration

**Covers**: REQ-KOK-NF-09, REQ-KOK-NF-10

**Files to modify**:
- `Core/Coordinator/AudioCoordinator.swift`
- `Features/Main/AudioViewModel.swift`

### Steps

1. **`AudioViewModel`**: Add `let ttsEngineSelector: TTSEngineSelector` alongside the existing `engineSelector: STTEngineSelector`:
   ```swift
   let ttsEngineSelector: TTSEngineSelector
   ```
   - Update `init(coordinator:audioManager:languagePairManager:setupManager:engineSelector:ttsEngineSelector:)`.
   - Update the convenience `init` to create a `TTSEngineSelector()` and pass its factories to `AudioCoordinator`:
     ```swift
     let ttsSelector = TTSEngineSelector()
     let coordinator = AudioCoordinator(
         ...
         outgoingTTSFactory: { [ttsSelector, lpm] deviceID in
             try ttsSelector.makeOutgoingService(for: lpm.targetLanguage ?? Locale.current, deviceID: deviceID)
         },
         incomingTTSFactory: { [ttsSelector, lpm] deviceID in
             try ttsSelector.makeIncomingService(for: lpm.sourceLanguage ?? Locale.current, deviceID: deviceID)
         },
         ...
     )
     self.init(..., ttsEngineSelector: ttsSelector)
     ```

2. **`AudioCoordinator`**: No structural changes needed — only the factory closures change (they already accept `AudioDeviceID?` and return `any SynthesisService`). Verify the types align.

3. **`AudioViewModel.preview()`** factory: pass `TTSEngineSelector()` as default.

### Tests

- Update `AudioViewModelTests` (if they exist) to pass a `TTSEngineSelector` in init.
- Verify the convenience `init` still compiles and wires correctly by running existing coordinator tests.

**Acceptance**: All existing `AudioCoordinatorTests` and `AudioViewModelTests` pass without regression.

---

## T7 — UI

**Covers**: REQ-KOK-01 (download sheet), REQ-KOK-16 through REQ-KOK-19 (voice selector + preview), REQ-KOK-20 (engine picker), REQ-KOK-22 (disabled when unavailable), REQ-KOK-25 (metrics panel)

**Files to create / modify**:
- `Features/Main/TTSMetricsView.swift` (NEW)
- `Features/Main/LanguagePairView.swift` (MODIFY)
- `Features/ContentView.swift` (MODIFY)

### Steps

1. **`TTSMetricsView.swift`** — mirror `STTMetricsView` exactly:
   ```swift
   struct TTSMetricsView: View {
       @State private var avSummary = TTSMetricsSummary.empty
       @State private var kokoroSummary = TTSMetricsSummary.empty

       var body: some View {
           DisclosureGroup("TTS Performance") {
               Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                   // Header row + AVSpeech row + Kokoro row
               }
               .font(.caption)
           }
           .onAppear { Task { await refreshSummaries() } }
       }

       private func refreshSummaries() async {
           async let av = TTSMetricsCollector.shared.summary(for: .avSpeech)
           async let kok = TTSMetricsCollector.shared.summary(for: .kokoro)
           (avSummary, kokoroSummary) = await (av, kok)
       }
   }
   ```

2. **`LanguagePairView.swift`** — add TTS engine section below the existing STT engine row:

   ```
   // TTS engine row (outgoing section)
   HStack {
       Text("TTS").font(.caption).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
       Picker("", selection: ttsEngineBinding) {
           ForEach(TTSEngine.allCases, id: \.self) { engine in
               Text(engine.displayName)
                   .tag(engine)
           }
       }
       .pickerStyle(.segmented)
       .disabled(!viewModel.ttsEngineSelector.kokoroAvailable && /* disable only Kokoro option */)

       if !viewModel.ttsEngineSelector.kokoroAvailable {
           Button("Download") { viewModel.ttsEngineSelector.downloadKokoroModel() }
               .buttonStyle(.borderless)
               .font(.caption)
       }
   }

   // Fallback badge
   if viewModel.ttsEngineSelector.usingFallback {
       Text("Kokoro: English only — using AVSpeech")
           .font(.caption2)
           .foregroundStyle(.orange)
   }

   // Voice selector (only when Kokoro is active and target locale is English)
   if viewModel.ttsEngineSelector.preferredEngine == .kokoro
       && viewModel.ttsEngineSelector.kokoroAvailable
       && !viewModel.ttsEngineSelector.usingFallback {
       voiceSelectorRow
   }
   ```

   **Voice selector row** (`voiceSelectorRow`):
   - `Picker("Voice", selection: voiceBinding)` listing available voices.
   - `Button("▶ Preview") { Task { await previewVoice() } }`.
   - Available voices: query `KokoroConfiguration` or `TTSEngineSelector` for the list.
   - If OQ-2 reveals voices via `VariantPreference`, populate from there; otherwise use a hardcoded list of known Kokoro voice IDs (e.g. `"af_heart"`, `"af_sky"`, `"bm_george"`) from the model card.

3. **`ContentView.swift`** — add Kokoro download sheet and `TTSMetricsView`:

   ```swift
   // State
   @State private var showKokoroDownload: Bool = false

   // In body, after STTMetricsView:
   TTSMetricsView()
       .padding(.horizontal, 2)

   // onChange
   .onChange(of: viewModel.ttsEngineSelector.isDownloading) { _, downloading in
       showKokoroDownload = downloading
   }

   // Sheet
   .sheet(isPresented: $showKokoroDownload) {
       kokoroDownloadSheet
   }
   ```

   **`kokoroDownloadSheet`**:
   ```swift
   private var kokoroDownloadSheet: some View {
       VStack(spacing: 16) {
           Text("Downloading Kokoro Model")
               .font(.headline)
           Text("≈ 300 MB · One-time download\nAll synthesis runs on-device.")
               .font(.caption)
               .foregroundStyle(.secondary)
               .multilineTextAlignment(.center)
           ProgressView()
               .scaleEffect(1.2)
           Button("Cancel") {
               viewModel.ttsEngineSelector.setPreferredEngine(.avSpeech)
               viewModel.ttsEngineSelector.unloadKokoroModel()
               showKokoroDownload = false
           }
           .buttonStyle(.bordered)
       }
       .padding(32)
       .frame(width: 280)
   }
   ```

4. Update `ContentView.frame(height:)`: increase from 620 to 680 to accommodate the new TTS row and `TTSMetricsView`.

### Acceptance (manual)

- TTS engine picker appears below STT picker; Kokoro option is greyed out until model is downloaded.
- Selecting Kokoro with non-English target shows fallback badge.
- Download sheet appears with spinner when `isDownloading = true`.
- Voice selector and preview button appear only when Kokoro is active and English is selected.
- TTSMetricsView appears in a collapsed disclosure group below STTMetricsView.

---

## T8 — Integration Tests + Cleanup

**Covers**: AC-01 through AC-10

**Files to create**:
- `TranslateCallTests/KokoroIntegrationTests.swift` (NEW — device-only, skipped in CI)

### Steps

1. Create `KokoroIntegrationTests` guarded by environment variable:
   ```swift
   @Suite(.enabled(if: ProcessInfo.processInfo.environment["RUN_INTEGRATION_TESTS"] == "1"))
   struct KokoroIntegrationTests { … }
   ```

2. **AC-01** (naturalness — manual only): Document test procedure in comments. No automated assertion for subjective quality.

3. **AC-02** (non-English → AVSpeech): Already covered by `TTSEngineSelectorTests.kokoroPreferenceNonEnglishUsesAVSpeech()`.

4. **AC-04** (network failure reverts engine): Already covered by `KokoroModelManagerTests.ensureReadySetsFailedOnError()`.

5. **AC-05** (latency ≤ 600ms on M1):
   ```swift
   @Test func synthesisLatencyUnder600ms() async throws {
       let mgr = KokoroModelManager.shared
       _ = try await mgr.ensureReady()  // warm up
       let svc = try KokoroSpeechService(outputDeviceID: nil)
       let start = Date()
       await svc.speak(text: "Hello, how are you today?", locale: Locale(identifier: "en-US"))
       try await Task.sleep(for: .milliseconds(800))
       let summary = await TTSMetricsCollector.shared.summary(for: .kokoro)
       #expect(summary.count >= 1)
       #expect(summary.avgLatencyMs <= 600)
   }
   ```

6. **AC-06** (protocol conformance): Compiler check — `KokoroSpeechService` conforming to `SynthesisService` is enforced at compile time. No runtime test needed.

7. **AC-09** (cache deletion mid-session):
   ```swift
   @Test func noCrashWhenCacheDeletedMidSession() async throws {
       _ = try await KokoroModelManager.shared.ensureReady()
       // Delete cache directory
       let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
           .appendingPathComponent("fluidaudio/Models/kokoro")
       try? FileManager.default.removeItem(at: cacheURL)
       // Attempt synthesis — should not crash, should either re-download or throw gracefully
       let svc = try KokoroSpeechService(outputDeviceID: nil)
       await svc.speak(text: "Test", locale: Locale(identifier: "en-US"))
       try await Task.sleep(for: .milliseconds(500))
       // No crash = pass
   }
   ```

8. **AC-10** (memory released): Instruments check only (document in comments). Verify `KokoroModelManager.unload()` is called and state transitions to `.idle`.

9. **SwiftLint cleanup**: Run `swiftlint` on all new files; fix any violations (line length, nesting, naming, identifier_name). Check that the `nonisolated(unsafe)` pattern comments are present on all relevant static lets.

10. **Full test suite regression**: Run `xcodebuild test` on the test target; confirm 0 regressions on all prior tests.

### Acceptance

- All unit tests (T1–T7) pass in CI.
- Integration tests pass on device with `RUN_INTEGRATION_TESTS=1`.
- SwiftLint: 0 errors, 0 warnings on new files.
- Existing test suite: 0 regressions.

---

## Summary Table

| Task | New Files | Modified Files | New Tests | Req Coverage |
|---|---|---|---|---|
| T0 | `KokoroTtsManaging.swift` | `project.pbxproj` | 0 | OQ-1–5, NF-09 |
| T1 | `TTSEngine.swift`, `TTSMetrics.swift`, `KokoroConfiguration.swift` | — | 5 | REQ-KOK-20,21,NF-09,10 |
| T2 | `TTSMetricsCollector.swift` | — | 6 | REQ-KOK-24–26 |
| T3 | `KokoroModelManager.swift` | — | 7 | REQ-KOK-01–07,NF-02–04 |
| T4 | `KokoroSpeechService.swift` | — | 7 | REQ-KOK-08–12,NF-01,05–08 |
| T5 | `TTSEngineSelector.swift` | — | 8 | REQ-KOK-13–23 |
| T6 | — | `AudioCoordinator.swift`, `AudioViewModel.swift` | 0 (+existing) | NF-09,10 |
| T7 | `TTSMetricsView.swift` | `LanguagePairView.swift`, `ContentView.swift` | 0 (manual) | REQ-KOK-01,16–22,25 |
| T8 | `KokoroIntegrationTests.swift` | — | 4 (device) | AC-01–10 |
| **Total** | **8 new** | **4 modified** | **≥ 37** | **All 26 REQs** |
