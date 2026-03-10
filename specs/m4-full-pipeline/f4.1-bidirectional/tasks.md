# F4.1 – Bidirectional Translation Pipeline — Task Breakdown

**Milestone**: M4 – Full Pipeline Integration
**Feature**: F4.1 – Bidirectional Translation
**Status**: DRAFT – Pending Gate 3 Review
**Date**: 2026-03-09
**Depends on**: F4.1 design.md (approved)

---

## Dependency Order

```
T1 → T2 → T3 → T4 (TranslationBridge refactor + second bridge)
T5 → T6           (SystemAudioCaptureService)
T7                (AVSpeechService device routing)
T8 (depends on T1,T2,T3,T4,T5,T6,T7) → AudioCoordinator
T9 (depends on T8) → AudioViewModel refactor
T10 (depends on T8,T9) → AppContainer wiring
T11 (depends on T9,T10) → UI updates
T12 (depends on T11) → integration smoke test
```

---

## Tasks

### T1 — Mock protocols for testing AudioCoordinator

**Req**: AC-4.1.1, AC-4.1.9, AC-4.1.10
**TDD phase**: Infrastructure

Create lightweight mock implementations of existing protocols needed by `AudioCoordinator` unit tests. These mocks live in the test target only.

**File**: `TranslateCallTests/Mocks/MockVADService.swift`
```swift
final class MockVADService: VADService, @unchecked Sendable {
    var activateCalled = false
    var deactivateCalled = false
    var speechSegments: AsyncStream<SpeechSegment> { ... }
    var vadStateEvents: AsyncStream<Bool> { ... }
    func activate(stream: AsyncStream<AVAudioPCMBuffer>) async throws { activateCalled = true }
    func deactivate() async { deactivateCalled = true }
}
```

**File**: `TranslateCallTests/Mocks/MockSpeechRecognizerService.swift`
**File**: `TranslateCallTests/Mocks/MockSynthesisService.swift`
**File**: `TranslateCallTests/Mocks/MockTranslationService.swift`
**File**: `TranslateCallTests/Mocks/MockSystemAudioCaptureService.swift`

Each mock records calls and allows injecting streams/results via continuations.

**Acceptance**: Mocks compile in test target with no warnings.
**Tests**: No tests yet — infrastructure only.

---

### T2 — `AVSpeechService` output device routing

**Req**: FR-4.1.7, FR-4.1.11, C-4.1.3
**TDD phase**: RED → GREEN → REFACTOR

Add optional `outputDeviceID: AudioDeviceID?` to `AVSpeechService.init()`. When non-nil, configure the engine's output to the specified CoreAudio device before starting.

**File**: `TranslateCall/Core/TTS/AVSpeechService.swift`

Changes:
- Add `init(outputDeviceID: AudioDeviceID? = nil) throws`
- Add `private func configureOutputDevice(_ id: AudioDeviceID) throws` using `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)`
- Call `configureOutputDevice` after `engine.prepare()`, before `engine.start()`
- Add `TTSError.deviceRoutingFailed` to error enum if not already present

**File**: `TranslateCallTests/TTSServiceTests.swift` — add:
```swift
@Test("AVSpeechService init with nil deviceID succeeds")
func initWithNilDeviceID() async throws { ... }

@Test("AVSpeechService init with nonexistent deviceID throws")
func initWithBadDeviceID() async throws {
    #expect(throws: TTSError.deviceRoutingFailed.self) {
        _ = try AVSpeechService(outputDeviceID: AudioDeviceID(99999))
    }
}
```

**Acceptance**: Existing 7 TTS tests still pass. Two new tests pass.

---

### T3 — `TranslationBridge` parametrization

**Req**: FR-4.1.19, C-4.1.1
**TDD phase**: RED → GREEN

Refactor `TranslationBridge` view from `@EnvironmentObject` to `init(model:)`.

**File**: `TranslateCall/App/TranslationBridge.swift`

Changes:
- Replace `@EnvironmentObject private var model: TranslationBridgeModel` with `private let model: TranslationBridgeModel`
- Add `init(model: TranslationBridgeModel)`

No other changes — `TranslationBridgeModel` API is unchanged.

**File**: `TranslateCallTests/TranslationBridgeTests.swift` — verify existing 8 tests still pass (they test `TranslationBridgeModel` directly, not the view).

**Acceptance**: All existing translation bridge tests pass. No new compiler warnings.

---

### T4 — `AppContainer` second bridge + wiring stub

**Req**: FR-4.1.19, AC-4.1.6
**TDD phase**: GREEN

Update `AppContainer` to create `incomingBridgeModel` and update `TranslateCallApp` to inject both bridges.

**File**: `TranslateCall/App/AppContainer.swift`

Changes:
```swift
let outgoingBridgeModel: TranslationBridgeModel  // renamed from translationBridgeModel
let incomingBridgeModel: TranslationBridgeModel   // NEW
// AudioCoordinator wiring comes in T8 — for now keep existing AudioViewModel
```

**File**: `TranslateCall/App/TranslateCallApp.swift`

Changes:
```swift
ZStack {
    ContentView()
    TranslationBridge(model: container.outgoingBridgeModel)
    TranslationBridge(model: container.incomingBridgeModel)   // NEW
}
.environmentObject(container.audioViewModel)
.environmentObject(container.languagePairManager)  // add if not already present
// Remove: .environmentObject(container.translationBridgeModel)
```

**Acceptance**: App builds and launches. Existing M3 one-way translation still works.

---

### T5 — `SystemAudioCaptureService` — core actor + buffer conversion

**Req**: FR-4.1.14, FR-4.1.15, FR-4.1.16, NFR-4.1.4
**TDD phase**: RED → GREEN → REFACTOR

Implement the SCStream-based audio capture actor. Focus: buffer conversion and downsampling. Permission and stream activation in T6.

**File**: `TranslateCall/Core/Audio/SystemAudioCaptureService.swift`

```swift
import AVFoundation
import ScreenCaptureKit

enum SystemAudioCaptureError: Error {
    case permissionDenied
    case noAppsAvailable
    case streamFailed(underlying: Error)
    case bufferConversionFailed
}

actor SystemAudioCaptureService: NSObject {
    private(set) var audioStream16kHz: AsyncStream<AVAudioPCMBuffer>
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    nonisolated(unsafe) private(set) var isActive: Bool = false

    // MARK: - Internal buffer conversion (testable in isolation)
    func convertToMono16k(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer?
}

extension SystemAudioCaptureService: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer buffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .audio else { return }
        // convert and yield — nonisolated, safe
    }
}
```

**File**: `TranslateCallTests/SystemAudioCaptureServiceTests.swift`

```swift
@Suite(.serialized)
struct SystemAudioCaptureServiceTests {
    @Test("CMSampleBuffer converts to 16kHz mono AVAudioPCMBuffer")
    func bufferConversion() async throws {
        // Create synthetic 48kHz stereo CMSampleBuffer
        // Call convertToMono16k(_:)
        // Verify output format: sampleRate=16000, channels=1
        // Verify frame count ≈ input_frames * (16000/48000)
    }

    @Test("convertToMono16k returns nil for non-audio buffer")
    func invalidBuffer() async throws { ... }

    @Test("deactivate while inactive is a no-op")
    func deactivateWhenInactive() async throws {
        let svc = SystemAudioCaptureService()
        await svc.deactivate()  // must not throw or crash
    }
}
```

Note: SCStream activation tests require Screen Recording permission — these are manual/integration only. Unit tests cover the conversion logic with synthetic buffers.

**Acceptance**: 3 new unit tests pass with `CODE_SIGN_IDENTITY="-"`.

---

### T6 — `SystemAudioCaptureService` — permission + activation

**Req**: FR-4.1.14, FR-4.1.15, FR-4.1.16, NFR-4.1.6, AC-4.1.7
**TDD phase**: GREEN

Implement SCStream permission request, app enumeration, and stream lifecycle.

**File**: `TranslateCall/Core/Audio/SystemAudioCaptureService.swift` (extend T5)

```swift
// New public methods:
func requestPermissionAndLoadApps() async throws -> [SCRunningApplication]
func activate(app: SCRunningApplication?) async throws
func deactivate() async
```

Internal `SCStreamConfiguration` setup (audio-only):
```swift
let config = SCStreamConfiguration()
config.capturesAudio = true
config.sampleRate = 48000
config.channelCount = 1
config.width = 2
config.height = 2
config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
config.excludesCurrentProcessAudioForMicrophoneSamples = true
```

`SCContentFilter` setup:
- If `app != nil`: `SCContentFilter(display: mainDisplay, includingApplications: [app], exceptingWindows: [])`
- If `app == nil`: `SCContentFilter(display: mainDisplay, excludingApplications: [self_app], exceptingWindows: [])`

**Entitlement**: Add `com.apple.security.screen-capture` to `TranslateCall.entitlements`.

**Additional unit test** (mock `SCShareableContent`):
```swift
@Test("requestPermissionAndLoadApps returns apps sorted by name")
func appsSortedByName() async throws {
    // Uses real SCShareableContent.current — requires Screen Recording permission
    // Mark as @Test(.disabled("Requires Screen Recording permission in CI"))
    // Manual validation only
}
```

**Acceptance**: `SystemAudioCaptureService` compiles with no errors. T5 tests still pass. Manual test: can activate and capture Zoom audio in a real session.

---

### T7 — BlackHole device ID resolver

**Req**: FR-4.1.7, design §5.4
**TDD phase**: GREEN

Add a static helper to resolve a `AudioDeviceID` by device name, usable by `AudioCoordinator`.

**File**: `TranslateCall/Core/Audio/AudioDevice.swift` (extend existing)

```swift
extension AudioDevice {
    /// Returns the CoreAudio DeviceID for the first device whose name contains `substring`.
    static func deviceID(forNameContaining substring: String) -> AudioDeviceID? {
        // Use AudioObjectGetPropertyData with kAudioHardwarePropertyDevices
        // Filter by kAudioObjectPropertyName
    }
}
```

**File**: `TranslateCallTests/AudioManagerTests.swift` — add:
```swift
@Test("deviceID returns nil for nonexistent device name")
func deviceIDForUnknownDevice() {
    let id = AudioDevice.deviceID(forNameContaining: "THIS_DEVICE_DOES_NOT_EXIST_XYZ")
    #expect(id == nil)
}
```

**Acceptance**: New test passes. `deviceID(forNameContaining: "BlackHole")` returns non-nil on a machine with BlackHole installed (manual validation).

---

### T8 — `AudioCoordinator` implementation

**Req**: FR-4.1.1..FR-4.1.13, FR-4.1.17, FR-4.1.18, AC-4.1.1..AC-4.1.5, AC-4.1.9, AC-4.1.10
**Depends on**: T1, T2, T3, T4, T5, T6, T7
**TDD phase**: RED → GREEN → REFACTOR

The core of F4.1. Implement `AudioCoordinator` as a `@MainActor ObservableObject` that owns and manages both pipelines using the mock protocols from T1.

**File**: `TranslateCall/Core/Audio/AudioCoordinator.swift`

Full implementation per design.md §3.2. Key points:
- Outgoing pipeline: reuses `AudioManager`, `VADServiceFactory`, `AppleSpeechService`, `AppleTranslationService`, `AVSpeechService`
- Incoming pipeline: `SystemAudioCaptureService`, `EnergyVADService`, `AppleSpeechService`, `AppleTranslationService`, `AVSpeechService`
- Exposes `isOutgoingSpeaking: Bool` and `isIncomingSpeaking: Bool` (hooks for F4.2, both always `false` in F4.1)
- `suppressIncomingPipeline(_:)` and `suppressOutgoingCapture(_:)` are no-ops (stubs for F4.2)

**File**: `TranslateCallTests/AudioCoordinatorTests.swift`

```swift
@Suite(.serialized) @MainActor
struct AudioCoordinatorTests {

    @Test("start() activates outgoing pipeline")
    func startActivatesOutgoing() async throws {
        let mocks = CoordinatorMocks()
        let coordinator = AudioCoordinator(mocks: mocks)
        try await coordinator.start(...)
        #expect(mocks.mockAudioManager.startCaptureCalled)
        #expect(mocks.mockVADFactory.activateCalled)
        #expect(mocks.mockOutgoingSTT.activateCalled)
    }

    @Test("start() skips incoming when capture permission denied")
    func startSkipsIncomingOnPermissionDenied() async throws {
        let mocks = CoordinatorMocks()
        mocks.mockCaptureService.throwOnActivate = SystemAudioCaptureError.permissionDenied
        let coordinator = AudioCoordinator(mocks: mocks)
        try await coordinator.start(...)
        #expect(coordinator.isIncomingActive == false)
        #expect(coordinator.errorAlert != nil)
        #expect(coordinator.isOutgoingActive == true)
    }

    @Test("stop() deactivates all services")
    func stopDeactivatesAll() async throws {
        let mocks = CoordinatorMocks()
        let coordinator = AudioCoordinator(mocks: mocks)
        try await coordinator.start(...)
        await coordinator.stop()
        #expect(mocks.mockOutgoingSTT.deactivateCalled)
        #expect(mocks.mockIncomingSTT.deactivateCalled)
        #expect(mocks.mockCaptureService.deactivateCalled)
        #expect(coordinator.isOutgoingActive == false)
        #expect(coordinator.isIncomingActive == false)
    }

    @Test("updateLanguagePair reconfigures both STT services")
    func updateLanguagePairReconfigures() async throws { ... }

    @Test("fatal AudioError stops both pipelines and sets errorAlert")
    func fatalErrorStopsBothPipelines() async throws { ... }

    @Test("non-fatal STT error on outgoing does not stop incoming")
    func nonFatalOutgoingErrorKeepsIncomingAlive() async throws { ... }

    @Test("language pair swap updates STT locales symmetrically")
    func languagePairSwap() async throws { ... }
}
```

**Acceptance**: All 6+ `AudioCoordinatorTests` pass. `** TEST SUCCEEDED **` verified.

---

### T9 — `AudioViewModel` refactor to observe `AudioCoordinator`

**Req**: All UI-facing requirements, AC-4.1.8
**Depends on**: T8
**TDD phase**: GREEN (refactor existing logic)

Migrate pipeline logic from `AudioViewModel` to `AudioCoordinator`. `AudioViewModel` becomes a thin Combine adapter.

**File**: `TranslateCall/Features/Main/AudioViewModel.swift`

Removed methods (logic moved to `AudioCoordinator`):
- `activateSTT(speechSegments:locale:)`
- `observeTranscriptions(_:)`
- `deactivateSTT()`
- `handleTranslation(of:)`
- `activateTTS()`
- `observeSynthesisState(_:)`
- `deactivateTTS()`
- `observeVADState(_:)`

Added:
- `@Published private(set) var incomingTranscription: String?`
- `@Published private(set) var incomingTranslation: String?`
- `@Published private(set) var isIncomingActive: Bool = false`
- `private let coordinator: AudioCoordinator`
- `private func bindCoordinator()` — Combine assignments from coordinator

`toggleCapture()` delegates to coordinator:
```swift
func toggleCapture() async {
    if isCapturing { await coordinator.stop() }
    else { try? await coordinator.start(...) }
}
```

**File**: `TranslateCallTests/AudioViewModelTests.swift` — verify existing tests (if any). Since `AudioViewModel` becomes a thin adapter, most logic is now tested via `AudioCoordinatorTests`.

**Acceptance**: App builds. Existing M3 one-way translation still works end-to-end on device.

---

### T10 — `AppContainer` full wiring

**Req**: FR-4.1.19, AC-4.1.6
**Depends on**: T8, T9
**TDD phase**: GREEN

Wire `AudioCoordinator` into `AppContainer`, replacing the inline pipeline setup.

**File**: `TranslateCall/App/AppContainer.swift`

```swift
@MainActor final class AppContainer: ObservableObject {
    let outgoingBridgeModel: TranslationBridgeModel
    let incomingBridgeModel: TranslationBridgeModel
    let audioCoordinator: AudioCoordinator
    let audioViewModel: AudioViewModel
    let languagePairManager: LanguagePairManager

    init() {
        let lpm = LanguagePairManager()
        let outBridge = TranslationBridgeModel()
        let inBridge = TranslationBridgeModel()
        let outTranslation = AppleTranslationService(model: outBridge)
        let inTranslation = AppleTranslationService(model: inBridge)
        let coordinator = AudioCoordinator(
            outgoingTranslationService: outTranslation,
            incomingTranslationService: inTranslation,
            languagePairManager: lpm
        )
        outgoingBridgeModel = outBridge
        incomingBridgeModel = inBridge
        languagePairManager = lpm
        audioCoordinator = coordinator
        audioViewModel = AudioViewModel(coordinator: coordinator, languagePairManager: lpm)
    }
}
```

**Acceptance**: App launches, both `TranslationBridge` instances appear in the ZStack (verified with Xcode View Hierarchy). Full one-way pipeline still functions.

---

### T11 — UI updates: 4-row transcript + capture app selector

**Req**: FR-4.1.21, FR-4.1.22, FR-4.1.23, AC-4.1.8
**Depends on**: T9, T10
**TDD phase**: GREEN

**File**: `TranslateCall/Features/Main/TranscriptionView.swift`

Extend to show incoming pipeline rows:
```swift
// Section header "↑ Outgoing"
// Row 1: outgoing transcription (gray)
// Row 2: outgoing translation (primary)
// Divider
// Section header "↓ Incoming" (only shown when isIncomingActive)
// Row 3: incoming transcription (gray, labeled "Remote:")
// Row 4: incoming translation (primary)
```

Parameters added: `incomingText: String?`, `incomingTranslation: String?`, `isIncomingActive: Bool`.

**File**: `TranslateCall/Features/Main/StatusBadgeView.swift`

Add `isIncomingActive: Bool` parameter. When true, show a headphone icon alongside the existing mic icon.

**File**: `TranslateCall/Features/Main/ContentView.swift`

Add capture source selector — a simple `Picker` below `DeviceSectionView`:
```swift
if viewModel.isIncomingActive || !viewModel.isCapturing {
    Picker("Capture from", selection: $viewModel.selectedCaptureApp) {
        Text("System audio").tag(nil as SCRunningApplication?)
        ForEach(viewModel.availableCaptureApps, id: \.processID) { app in
            Text(app.applicationName).tag(app as SCRunningApplication?)
        }
    }
}
```

`availableCaptureApps: [SCRunningApplication]` is populated by `AudioCoordinator.requestCaptureApps()` on first session start.

**Window frame**: Increase height from 440 to 520 to accommodate the additional rows.

**Acceptance**: UI shows 4 text rows during active bidirectional session. Capture app picker visible when session is stopped.

---

### T12 — End-to-end integration smoke test + all tests green

**Req**: All acceptance criteria
**Depends on**: T1–T11
**TDD phase**: Validation

Run full test suite and verify `** TEST SUCCEEDED **`:

```bash
xcodebuild test \
  -project TranslateCall.xcodeproj \
  -scheme TranslateCall \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO
```

**Expected passing test counts** (approximate):
- `AudioManagerTests`: existing count (unchanged)
- `STTServiceTests`: 28 (unchanged)
- `TTSServiceTests`: existing + 2 new (T2)
- `TranslationBridgeTests`: 8 (unchanged)
- `LanguagePairManagerTests`: 8 (unchanged)
- `TranslationPipelineTests`: 5 (unchanged)
- `SystemAudioCaptureServiceTests`: 3 new (T5)
- `AudioCoordinatorTests`: 6+ new (T8)
- `AudioManagerTests` extension: +1 new (T7)

**Manual smoke test on device** (after full test suite passes):
1. Launch app → Start session
2. Speak English → hear Spanish from BlackHole (verify in Zoom test call)
3. Play Spanish audio in Zoom → app captures → hears English from speakers
4. Stop session → no dangling tasks (verify with Instruments Leaks)
5. Change language pair mid-session → both pipelines adapt < 500ms

**Acceptance**: `** TEST SUCCEEDED **` with no regressions. Manual smoke test passes.

---

## Summary Table

| Task | File(s) | New Tests | Depends |
|------|---------|-----------|---------|
| T1 | `Tests/Mocks/Mock*.swift` | 0 (infrastructure) | — |
| T2 | `AVSpeechService.swift` | +2 | — |
| T3 | `TranslationBridge.swift` | 0 (refactor) | — |
| T4 | `AppContainer.swift`, `TranslateCallApp.swift` | 0 | T3 |
| T5 | `SystemAudioCaptureService.swift` | +3 | — |
| T6 | `SystemAudioCaptureService.swift`, entitlements | +1 (disabled in CI) | T5 |
| T7 | `AudioDevice.swift` | +1 | — |
| T8 | `AudioCoordinator.swift` | +6 | T1,T2,T5,T6,T7 |
| T9 | `AudioViewModel.swift` | 0 (refactor) | T8 |
| T10 | `AppContainer.swift` | 0 | T8,T9 |
| T11 | `TranscriptionView.swift`, `StatusBadgeView.swift`, `ContentView.swift` | 0 (UI) | T9,T10 |
| T12 | — | 0 (validation) | T1–T11 |

**Total new tests**: ~13 unit tests + 1 disabled CI test + manual integration

---

## TDD Cycle per Task

Each task follows:
1. **RED**: Write the test(s) first — they fail to compile or fail at runtime
2. **GREEN**: Write the minimum implementation to make tests pass
3. **REFACTOR**: Clean up, remove duplication, verify no warnings

---

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| `AVAudioEngine.outputNode.audioUnit` is nil | Check for nil, throw `TTSError.deviceRoutingFailed`, log warning (T2) |
| SCStream permission UI breaks CI | Mark SCStream activation tests as `.disabled("Requires Screen Recording")` (T6) |
| `AudioCoordinator` task leaks on stop | `@Suite(.serialized)` + explicit Task cancellation check in T8 stop test |
| BlackHole not installed on test machine | `deviceID(forNameContaining:)` returns nil → coordinator falls back to system default (T7) |
| `CMSampleBuffer.withAudioBufferList` availability | Requires macOS 13+ — already within our 15.0+ target (T5) |

---

*End of F4.1 Task Breakdown — Gate 3 Review Pending*
