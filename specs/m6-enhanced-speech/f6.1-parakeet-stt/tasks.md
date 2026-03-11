# F6.1 — FluidAudio Parakeet STT: Task Breakdown

> **Feature**: F6.1 — FluidAudio Parakeet STT Integration
> **Milestone**: M6 — Enhanced STT/TTS
> **Status**: DRAFT
> **Depends on**: design.md (approved)
> **Date**: 2026-03-11

---

## Overview

8 tasks in dependency order. Each task is independently testable and maps to a TDD cycle (RED → GREEN → REFACTOR).

```
T1 (types) ──▶ T2 (model manager) ──▶ T3 (service) ──▶ T4 (selector)
                                                              │
                                          T5 (coordinator) ◀─┘
                                          T6 (metrics)
                                          T7 (UI)        ◀── T4, T5, T6
                                          T8 (tests)     ◀── T1–T7
```

---

## T1 — Shared Types

**Covers**: REQ-PAR-17, REQ-PAR-18, REQ-PAR-NF-08

**Files to create / modify**:
- `Core/STT/STTEngine.swift` (NEW)
- `Core/STT/STTMetrics.swift` (NEW)
- `Core/STT/ParakeetConfiguration.swift` (NEW)

### Steps

1. Create `STTEngine.swift`:
   - `public enum STTEngine: String, Codable, Sendable, CaseIterable`
   - Cases: `.appleSpeech`, `.parakeet`
   - `var displayName: String`
   - `func supports(locale: Locale) -> Bool` — returns `true` for `.appleSpeech` always; for `.parakeet` only when `locale.language.languageCode?.identifier == "en"`

2. Create `STTMetrics.swift`:
   - `public struct STTMetrics: Sendable` with fields: `engine`, `segmentDurationMs`, `transcriptionLatencyMs`, `confidence`, `textLength`, `timestamp`

3. Create `ParakeetConfiguration.swift`:
   - `public struct ParakeetConfiguration: Sendable` with `modelVersion: AsrModelVersion` and `preferANE: Bool`
   - `nonisolated(unsafe) public static let default = ParakeetConfiguration(modelVersion: .v3, preferANE: true)`

### Tests (RED first)

```swift
// TranslateCallTests/STTEngineTests.swift
@Test func parakeetSupportsEnglish() { #expect(STTEngine.parakeet.supports(locale: Locale(identifier: "en-US"))) }
@Test func parakeetRejectsFrench() { #expect(!STTEngine.parakeet.supports(locale: Locale(identifier: "fr-FR"))) }
@Test func appleSpeechSupportsAll() { #expect(STTEngine.appleSpeech.supports(locale: Locale(identifier: "zh-Hant"))) }
@Test func rawValueRoundTrip() { #expect(STTEngine(rawValue: "parakeet") == .parakeet) }
```

**Acceptance**: All 4 tests pass. `STTEngine` is Codable.

---

## T2 — `ParakeetModelManager`

**Covers**: REQ-PAR-01 through REQ-PAR-06, REQ-PAR-NF-02, REQ-PAR-NF-03, REQ-PAR-NF-04

**Files to create**:
- `Core/STT/ParakeetModelManager.swift` (NEW)

### Steps

1. Define `ParakeetModelManager` as an `actor` with `static let shared`.

2. Define the `State` enum inside the actor:
   - `.idle`, `.downloading`, `.loading`, `.ready(AsrManager)`, `.failed(Error)`
   - Add `@Published`-equivalent: expose state changes via `AsyncStream<State>` so UI can observe.

3. Implement `ensureReady(config:) async throws -> AsrManager`:
   - Fast path: `.ready(mgr)` → return `mgr`
   - Coalesce concurrent callers: store in-flight `Task<AsrManager, Error>?`; if one is running, await it
   - Try `loadFromCache`: `AsrModels.loadFromCache(configuration: mlConfig, version: config.modelVersion)`
   - On failure, call `downloadAndLoad`

4. Implement `redownload(config:) async throws`:
   - Delete cached directory (if exists) using `FileManager`
   - Reset state to `.idle`
   - Call `ensureReady`

5. Implement `unload()`:
   - Call `asrManager.cleanup()` (if `.ready`)
   - Set state to `.idle`

6. Build `MLModelConfiguration` from `ParakeetConfiguration.preferANE`:
   ```swift
   let mlConfig = MLModelConfiguration()
   mlConfig.computeUnits = config.preferANE ? .all : .cpuAndGPU
   ```

7. **Spike**: Check whether `AsrModels.downloadAndLoad` or `AsrModels.download` exposes byte progress. If yes, add `var downloadProgress: Double` published property. If no, use `0.5` placeholder (indeterminate).

### Tests

```swift
// TranslateCallTests/ParakeetModelManagerTests.swift
// Use a mock/subclass approach or dependency-inject an AsrModels factory closure.

@Test func idleStateOnInit() async {
    let manager = ParakeetModelManager()  // fresh instance (not .shared)
    if case .idle = await manager.state { } else { Issue.record("expected idle") }
}

@Test func failedStateOnDownloadError() async {
    // Inject a factory that throws AsrModelsError.downloadFailed("mock")
    // ensureReady should set state = .failed
}

@Test func concurrentCallersGetSameResult() async throws {
    // Two concurrent tasks calling ensureReady; only one download should occur
    // Use a counting mock factory
}
```

**Acceptance**: State machine transitions correctly; concurrent callers share the same in-flight task.

---

## T3 — `ParakeetSpeechService`

**Covers**: REQ-PAR-07 through REQ-PAR-14, REQ-PAR-NF-01, REQ-PAR-NF-06, REQ-PAR-NF-07

**Files to create**:
- `Core/STT/ParakeetSpeechService.swift` (NEW)

### Steps

1. Declare `actor ParakeetSpeechService: SpeechRecognizerService`.

2. Properties:
   - `nonisolated(unsafe) private(set) var locale: Locale`
   - `var transcriptionStream: AsyncStream<TranscriptionResult>` (back by stored continuation)
   - `private let configuration: STTConfiguration`
   - `private let parakeetConfig: ParakeetConfiguration`
   - `private var continuation: AsyncStream<TranscriptionResult>.Continuation?`
   - `private var asrManager: AsrManager?`

3. Implement `activate() async throws`:
   - English guard: `locale.language.languageCode?.identifier == "en"` else throw `STTError.languageUnavailable`
   - `asrManager = try await ParakeetModelManager.shared.ensureReady(config: parakeetConfig)`
   - Create `AsyncStream`, store `continuation`

4. Implement `deactivate() async`:
   - `continuation?.finish()`
   - `continuation = nil`
   - `asrManager?.resetState()`

5. Implement `setLocale(_ locale: Locale) throws`:
   - Guard English — else throw `STTError.languageUnavailable`
   - Update `self.locale`

6. Implement internal `func transcribe(segment: SpeechSegment) async`:
   - Guard `asrManager != nil` else return
   - Start clock
   - Call `segment.buffer.toFloatArray()`
   - Truncate to `ASRConstants.maxModelSamples` (240_000) if needed; log warning
   - `let result = try await asrManager.transcribe(samples, source: .microphone)`
   - Compute latency
   - Call `STTMetricsCollector.shared.record(…)`
   - Discard if `result.confidence < configuration.minimumConfidence`
   - `continuation?.yield(TranscriptionResult(text:confidence:locale:timestamp:))`
   - Map `ASRError` → `STTError` on catch

7. Add `AVAudioPCMBuffer.toFloatArray()` extension in `SpeechRecognizerService.swift`:
   ```swift
   extension AVAudioPCMBuffer {
       func toFloatArray() -> [Float] {
           guard let data = floatChannelData else { return [] }
           return Array(UnsafeBufferPointer(start: data[0], count: Int(frameLength)))
       }
   }
   ```
   Verify 16kHz sample rate; throw `STTError.failure("invalid_sample_rate")` if not.

8. Wire `SpeechSegment` → `transcribe` in `AudioCoordinator` integration (done in T5).

### Tests

```swift
// TranslateCallTests/ParakeetSpeechServiceTests.swift

@Test func setLocaleEnglishSucceeds() throws {
    let svc = ParakeetSpeechService(locale: Locale(identifier: "en-US"))
    try svc.setLocale(Locale(identifier: "en-GB"))
}

@Test func setLocaleFrenchThrows() {
    let svc = ParakeetSpeechService(locale: Locale(identifier: "en-US"))
    #expect(throws: STTError.languageUnavailable) {
        try svc.setLocale(Locale(identifier: "fr-FR"))
    }
}

@Test func truncatesLongSegment() async throws {
    // Create a mock AsrManager that captures input sample count
    // Submit a buffer with 300_000 samples
    // Verify mock received exactly 240_000 samples
}

@Test func discardsLowConfidenceResult() async throws {
    // Mock AsrManager returns ASRResult with confidence = 0.3
    // Verify transcriptionStream receives no element
}

@Test func mapsAsrErrorToSTTError() async throws {
    // Mock AsrManager throws ASRError.notInitialized
    // Verify caught and mapped to STTError.failure
}
```

**Acceptance**: All tests pass without real model download.

---

## T4 — `STTEngineSelector`

**Covers**: REQ-PAR-13 through REQ-PAR-19

**Files to create**:
- `Core/STT/STTEngineSelector.swift` (NEW)

### Steps

1. Declare `@MainActor final class STTEngineSelector: ObservableObject`.

2. `@Published` properties:
   - `private(set) var activeEngine: STTEngine`
   - `private(set) var parakeetAvailable: Bool = false`
   - `private(set) var usingFallback: Bool = false`
   - `var preferredEngine: STTEngine { didSet { persist() } }`

3. Service instances:
   - `private(set) var outgoingService: any SpeechRecognizerService`
   - `private(set) var incomingService: any SpeechRecognizerService`

4. `init(defaults: UserDefaults = .standard, appleSpeechFactory: () -> any SpeechRecognizerService, parakeetFactory: () -> any SpeechRecognizerService)`:
   - Load `preferredEngine` from defaults key `tlk.stt.engine`; default `.appleSpeech`
   - Both services start as `appleSpeechFactory()`
   - Start background Task to `await ParakeetModelManager.shared.ensureReady()` → set `parakeetAvailable = true`

5. `func updateLocales(source: Locale, target: Locale) async`:
   - Apply resolution logic from design §5.1
   - Deactivate old services; activate new services

6. `func setPreference(_ engine: STTEngine) async`:
   - Update `preferredEngine` → persist
   - If `.parakeet` and model not downloaded → trigger `ParakeetModelManager.shared.ensureReady()`
   - Call `updateLocales` with current locales

7. `private func persist()`:
   - `defaults.set(preferredEngine.rawValue, forKey: "tlk.stt.engine")`

### Tests

```swift
// TranslateCallTests/STTEngineSelectorTests.swift

@Test func defaultEngineIsAppleSpeech() async {
    let selector = STTEngineSelector(defaults: .init(suiteName: "test")!, …)
    #expect(selector.preferredEngine == .appleSpeech)
}

@Test func persistsPreference() async {
    let defaults = UserDefaults(suiteName: "test_persist")!
    let selector = STTEngineSelector(defaults: defaults, …)
    await selector.setPreference(.parakeet)
    #expect(defaults.string(forKey: "tlk.stt.engine") == "parakeet")
}

@Test func nonEnglishLocaleUsesFallback() async {
    // parakeetAvailable = true; source = fr-FR
    // updateLocales → usingFallback == true; both services == AppleSpeechService
}

@Test func englishLocaleUsesParakeet() async {
    // parakeetAvailable = true; preferred = .parakeet; source = en-US
    // updateLocales → outgoingService == ParakeetSpeechService; usingFallback == false
}
```

**Acceptance**: Engine resolution logic is correct for all 4 combinations of (English/non-English × Parakeet available/unavailable).

---

## T5 — `AudioCoordinator` Integration

**Covers**: REQ-PAR-07, REQ-PAR-NF-08

**Files to modify**:
- `Core/Coordinator/AudioCoordinator.swift`

### Steps

1. Replace direct `AppleSpeechService` instantiation with `STTEngineSelector` injection.

2. Change `AudioCoordinator.init` to accept an `STTEngineSelector` (or factory closure) instead of creating its own STT services.

3. Replace `outgoingSTT` and `incomingSTT` references with `engineSelector.outgoingService` and `engineSelector.incomingService`.

4. Wire `AudioCoordinator.start()` to call `await engineSelector.updateLocales(source:target:)` after language pair is resolved.

5. In `handleSpeechSegment(segment:pipeline:)`, pass the segment to the active service's `transcribe` method (already generic through protocol — no changes needed if the protocol is followed).

6. Ensure `deactivate()` calls `engineSelector.outgoingService.deactivate()` and `engineSelector.incomingService.deactivate()`.

### Tests

Update `AudioCoordinatorTests.swift`:
- Inject a mock `STTEngineSelector` with mock services
- Verify that `start()` calls `engineSelector.updateLocales`
- Verify segments are routed to `outgoingService` / `incomingService` as expected

**Acceptance**: Existing coordinator tests pass; no regression on T1–T12 from F4.1.

---

## T6 — `STTMetricsCollector`

**Covers**: REQ-PAR-20 through REQ-PAR-22

**Files to create**:
- `Core/STT/STTMetricsCollector.swift` (NEW)

### Steps

1. Declare `actor STTMetricsCollector` with `static let shared`.

2. `private(set) var recent: [STTMetrics] = []` capped at 100 entries.

3. `func record(_ metrics: STTMetrics)` — append and trim if over cap.

4. `func summary(for engine: STTEngine) -> (avgLatencyMs: Double, avgConfidence: Double, count: Int)`:
   - Filter by engine; compute averages; return zeros for empty.

5. `func reset()` — clears all entries (used in tests and on app restart if desired).

### Tests

```swift
// TranslateCallTests/STTMetricsCollectorTests.swift

@Test func recordAndSummary() async {
    let collector = STTMetricsCollector()
    await collector.record(STTMetrics(engine: .parakeet, segmentDurationMs: 5000, transcriptionLatencyMs: 300, confidence: 0.9, textLength: 20, timestamp: .now))
    let summary = await collector.summary(for: .parakeet)
    #expect(summary.avgLatencyMs == 300)
    #expect(summary.avgConfidence == 0.9)
}

@Test func capsAt100() async {
    let collector = STTMetricsCollector()
    for i in 0..<110 {
        await collector.record(STTMetrics(engine: .appleSpeech, …))
    }
    #expect(await collector.recent.count == 100)
}

@Test func summaryForMissingEngineReturnsZero() async {
    let collector = STTMetricsCollector()
    let summary = await collector.summary(for: .parakeet)
    #expect(summary.count == 0)
}
```

**Acceptance**: All 3 tests pass.

---

## T7 — UI

**Covers**: REQ-PAR-01 (progress sheet), REQ-PAR-17 (picker), REQ-PAR-21 (metrics panel)

**Files to create / modify**:
- `Features/Main/STTMetricsView.swift` (NEW)
- `Features/Main/LanguagePairView.swift` (MODIFY — add engine picker)
- `App/ContentView.swift` (MODIFY — model download sheet)

### Steps

1. **Engine picker in `LanguagePairView`**:
   ```swift
   Picker("STT Engine", selection: $viewModel.engineSelector.preferredEngine) {
       ForEach(STTEngine.allCases, id: \.self) { engine in
           Text(engine.displayName).tag(engine)
       }
   }
   .pickerStyle(.radioGroup)
   .disabled(!viewModel.engineSelector.parakeetAvailable && /* Parakeet row only */)
   ```
   - Below picker: `if viewModel.engineSelector.usingFallback { Text("Parakeet: English only — using Apple Speech").font(.caption).foregroundStyle(.secondary) }`
   - "Download" button when Parakeet not yet available: triggers `ParakeetModelManager.shared.redownload()`

2. **Model download sheet in `ContentView`**:
   ```swift
   .sheet(isPresented: $showingParakeetDownload) {
       VStack {
           Text("Downloading Parakeet model").font(.headline)
           Text("≈ 800 MB · One-time download").font(.caption)
           ProgressView()
           Button("Cancel") { Task { await ParakeetModelManager.shared.unload() } }
       }
   }
   ```
   - `showingParakeetDownload` driven by `ParakeetModelManager.state == .downloading`
   - Expose state changes via `@Published` wrapper in `AudioViewModel` or direct `@StateObject` in ContentView

3. **`STTMetricsView`**:
   ```swift
   struct STTMetricsView: View {
       @State private var appleSummary: (Double, Double, Int) = (0, 0, 0)
       @State private var parakeetSummary: (Double, Double, Int) = (0, 0, 0)
       var body: some View { … Grid showing both engines … }
   }
   ```
   - Refreshes on appear using `Task { async let a = ...; async let b = ... }`
   - Placed in a disclosure group "STT Performance" at the bottom of the main window.

### Acceptance

- Manual: Engine picker shows correctly; selecting Parakeet when not downloaded triggers download sheet.
- Manual: Fallback badge appears when source language is not English.
- Manual: Metrics panel updates after each transcription cycle.

---

## T8 — Integration Tests & Cleanup

**Covers**: AC-01 through AC-08

**Files to create / modify**:
- `TranslateCallTests/ParakeetIntegrationTests.swift` (NEW — device-only, skipped in CI)

### Steps

1. Create `ParakeetIntegrationTests` annotated with `@Suite(.enabled(if: ProcessInfo.processInfo.environment["RUN_INTEGRATION_TESTS"] == "1"))`.

2. Test AC-01 (accuracy comparison):
   - Load a reference 5-second English WAV from test bundle
   - Transcribe with both engines
   - Assert Parakeet confidence ≥ Apple Speech confidence (or both > 0.75)

3. Test AC-05 (latency):
   - Transcribe reference WAV with Parakeet
   - Assert latency ≤ 800 ms on M1 hardware

4. Test AC-08 (model deleted mid-session):
   - Load model; delete cache directory; submit segment
   - Assert no crash; `STTError` propagated

5. **Cleanup / SwiftLint**: Run `swiftlint` on all new files. Fix any violations (line length, nesting, naming).

6. **Run full test suite** to confirm zero regression on existing tests.

### Acceptance

- All unit tests (T1–T6) pass in CI (no real model download)
- Integration tests pass on device with `RUN_INTEGRATION_TESTS=1`
- SwiftLint: 0 errors, 0 warnings on new files
- Existing test suite: 0 regressions

---

## Summary Table

| Task | Files | New Tests | Req Coverage |
|------|-------|-----------|--------------|
| T1 | STTEngine, STTMetrics, ParakeetConfiguration | 4 | REQ-PAR-17,18,NF-08 |
| T2 | ParakeetModelManager | 3 | REQ-PAR-01–06,NF-02–04 |
| T3 | ParakeetSpeechService | 5 | REQ-PAR-07–14,NF-01,06,07 |
| T4 | STTEngineSelector | 4 | REQ-PAR-13–19 |
| T5 | AudioCoordinator (modify) | 2 | REQ-PAR-07,NF-08 |
| T6 | STTMetricsCollector | 3 | REQ-PAR-20–22 |
| T7 | STTMetricsView, LanguagePairView, ContentView | 0 (manual) | REQ-PAR-01,17,21 |
| T8 | ParakeetIntegrationTests | 3 (device) | AC-01,05,08 |
| **Total** | **9 files new, 3 modified** | **≥ 24** | |
