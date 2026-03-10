# F4.1 – Bidirectional Translation Pipeline — Technical Design

**Milestone**: M4 – Full Pipeline Integration
**Feature**: F4.1 – Bidirectional Translation
**Status**: DRAFT – Pending Gate 2 Review
**Date**: 2026-03-09
**Depends on**: F4.1 requirements.md (approved)

---

## 1. Architecture Overview

### 1.1 Decision: Mechanism B (SCStream) as primary capture

**Decision**: Use `ScreenCaptureKit SCStream` for system audio capture (Mechanism B from requirements), with graceful fallback when permission is denied.

**Rationale**:
- macOS 15.0+ is our deployment target — SCStream is stable and recommended by Apple for this use case (WWDC24).
- SCStream can target a specific running app (Zoom/Teams/Meet), avoiding unrelated system audio.
- No manual Audio MIDI Setup configuration required from the user.
- Screen Recording permission dialog is familiar to macOS users (commonly requested by meeting apps).
- Virtual device fallback (Mechanism A) remains valid if the user denies Screen Recording — in that case the incoming pipeline is disabled with an actionable error.

**Consequence**: `com.apple.security.screen-capture` entitlement must be added to the app.

### 1.2 Decision: AudioCoordinator as the coordination layer

`AudioViewModel` grows as a UI-facing adapter. A new `AudioCoordinator` owns the two pipeline objects and their lifecycle, keeping `AudioViewModel` focused on SwiftUI binding.

### 1.3 Decision: Parameterized `TranslationBridge`

The existing `TranslationBridge` view uses `@EnvironmentObject var model: TranslationBridgeModel`. To support two bridge instances in the same SwiftUI hierarchy, we change it to accept the model as an `init` parameter. This is a **non-breaking refactor** — the call site in `TranslateCallApp` changes but the `TranslationBridgeModel` API is unchanged.

### 1.4 Decision: `AVSpeechService` output device routing via CoreAudio

To route outgoing TTS to BlackHole and incoming TTS to speakers, `AVSpeechService` gains an optional `outputDeviceID: AudioDeviceID?` init parameter. When non-nil, the CoreAudio property `kAudioOutputUnitProperty_CurrentDevice` is set on the engine's output audio unit **before** the engine starts. This is the standard macOS mechanism for directing AVAudioEngine output to a specific device.

---

## 2. Object Graph

```
AppContainer (@MainActor ObservableObject)
├── outgoingBridgeModel: TranslationBridgeModel          [M3 — refactored from @EnvironmentObject]
├── incomingBridgeModel: TranslationBridgeModel          [NEW]
├── audioCoordinator: AudioCoordinator                   [NEW]
│   ├── Outgoing pipeline (M3 components, now owned by coordinator)
│   │   ├── audioManager: AudioManager
│   │   ├── vadFactory: VADServiceFactory
│   │   ├── sttService: AppleSpeechService(locale: A)
│   │   ├── translationService: AppleTranslationService(model: outgoingBridgeModel)
│   │   └── ttsService: AVSpeechService(outputDeviceID: blackHoleDeviceID)
│   └── Incoming pipeline (NEW components)
│       ├── captureService: SystemAudioCaptureService     [NEW actor]
│       ├── vadService: EnergyVADService                  [reused, new instance]
│       ├── sttService: AppleSpeechService(locale: B)    [reused, new instance]
│       ├── translationService: AppleTranslationService(model: incomingBridgeModel) [new instance]
│       └── ttsService: AVSpeechService(outputDeviceID: nil = system default)
└── audioViewModel: AudioViewModel                       [observes AudioCoordinator]
```

### SwiftUI Scene

```
TranslateCallApp
└── WindowGroup
    └── ZStack
        ├── ContentView
        ├── TranslationBridge(model: container.outgoingBridgeModel)   [refactored]
        └── TranslationBridge(model: container.incomingBridgeModel)   [NEW]
    .environmentObject(container.audioViewModel)
    .environmentObject(container.languagePairManager)
```

---

## 3. New Components

### 3.1 `SystemAudioCaptureService` (actor)

**File**: `TranslateCall/Core/Audio/SystemAudioCaptureService.swift`

Wraps `ScreenCaptureKit` to provide an `AsyncStream<AVAudioPCMBuffer>` at 16 kHz mono, matching the format of `AudioManager.audioStream16kHz`.

```swift
actor SystemAudioCaptureService {
    // MARK: - Public API

    /// 16 kHz mono PCM buffers from the captured system audio source.
    var audioStream16kHz: AsyncStream<AVAudioPCMBuffer> { get }

    /// Requests Screen Recording permission and lists capturable apps.
    func requestPermissionAndLoadApps() async throws -> [SCRunningApplication]

    /// Activate capture from the given application (or all apps if nil).
    func activate(app: SCRunningApplication?) async throws

    /// Deactivate and release all SCStream resources.
    func deactivate() async

    /// True after activate() returns successfully.
    var isActive: Bool { get }
}
```

**Internal flow**:
1. `requestPermissionAndLoadApps()`:
   - `SCShareableContent.current` — async, throws if no permission
   - Returns `content.applications` sorted by name
2. `activate(app:)`:
   - Build `SCContentFilter`: if `app != nil`, use `SCContentFilter(desktopIndependentWindow:...)` scoped to the app; otherwise use `SCContentFilter(display:excludingApplications:exceptingWindows:)` for full system audio
   - Build `SCStreamConfiguration`: `capturesAudio = true`, `sampleRate = 48000`, `channelCount = 1`, `width = 1, height = 1` (minimal video footprint — audio only stream)
   - Create `SCStream(filter:configuration:delegate:)` (delegate = self via `SCStreamDelegate`)
   - Add `SCStreamOutput` for `.audio` type
   - `stream.startCapture()` — async throws
   - Initialize `AVAudioConverter` for 48kHz→16kHz downsampling
3. `SCStreamOutput.stream(_:didOutputSampleBuffer:of:)`:
   - Convert `CMSampleBuffer` → `AVAudioPCMBuffer` using `withAudioBufferList`
   - Downsample 48kHz → 16kHz via `AVAudioConverter`
   - Yield into `AsyncStream`
4. `deactivate()`:
   - `stream.stopCapture()`
   - Finish `AsyncStream` continuation

**Error types**:
```swift
enum SystemAudioCaptureError: Error {
    case permissionDenied
    case noAppsAvailable
    case streamFailed(underlying: Error)
}
```

**Thread model**: Callbacks from `SCStream` arrive on an arbitrary background thread. The `SCStreamOutput` bridge is `nonisolated`, converts the buffer on-thread, then `yield`s into the `AsyncStream` (which is safe — `AsyncStream.Continuation.yield` is sendable).

### 3.2 `AudioCoordinator` (@MainActor ObservableObject)

**File**: `TranslateCall/Core/Audio/AudioCoordinator.swift`

Owns both pipelines, manages their lifecycle, and publishes combined state to `AudioViewModel`.

```swift
@MainActor
final class AudioCoordinator: ObservableObject {

    // MARK: - Outgoing pipeline state
    @Published private(set) var outgoingTranscription: String?
    @Published private(set) var outgoingTranslation: String?
    @Published private(set) var isOutgoingSpeaking: Bool = false     // consumed by F4.2
    @Published private(set) var isOutgoingActive: Bool = false

    // MARK: - Incoming pipeline state
    @Published private(set) var incomingTranscription: String?
    @Published private(set) var incomingTranslation: String?
    @Published private(set) var isIncomingSpeaking: Bool = false     // consumed by F4.2
    @Published private(set) var isIncomingActive: Bool = false

    // MARK: - Shared state
    @Published private(set) var errorAlert: AlertItem?
    @Published private(set) var isSpeechActive: Bool = false         // from outgoing VAD
    @Published private(set) var isStarting: Bool = false

    // MARK: - Public actions
    func start(
        languagePair: LanguagePairManager,
        captureApp: SCRunningApplication?,
        blackHoleDeviceID: AudioDeviceID?
    ) async throws

    func stop() async

    func updateLanguagePair(_ manager: LanguagePairManager) async
}
```

**Outgoing pipeline** (owned objects):
- `audioManager: AudioManager`
- `vadFactory: VADServiceFactory`
- `outgoingSTT: AppleSpeechService`
- `outgoingTranslation: AppleTranslationService` (uses `outgoingBridgeModel`)
- `outgoingTTS: AVSpeechService(outputDeviceID: blackHoleDeviceID)`
- `outgoingTasks: [Task<Void,Never>]` — observation tasks

**Incoming pipeline** (owned objects):
- `captureService: SystemAudioCaptureService`
- `incomingVAD: EnergyVADService` (Energy-only for MVP; see §5.3)
- `incomingSTT: AppleSpeechService`
- `incomingTranslation: AppleTranslationService` (uses `incomingBridgeModel`)
- `incomingTTS: AVSpeechService(outputDeviceID: nil)`
- `incomingTasks: [Task<Void,Never>]`

**Lifecycle**:
```
start():
  1. isStarting = true
  2. try audioManager.startCapture()
  3. try vadFactory.service.activate(stream: audioManager.audioStream16kHz)
  4. observeOutgoingVAD()
  5. try outgoingSTT.activate(stream: vadFactory.service.speechSegments, locale: A)
  6. observeOutgoingTranscriptions()
  7. outgoingTTS.activate() [init AVSpeechService with BlackHole deviceID]
  8. observeOutgoingTTSState()
  9. if captureService permission available:
     10. try captureService.activate(app: captureApp)
     11. try incomingVAD.activate(stream: captureService.audioStream16kHz)
     12. try incomingSTT.activate(stream: incomingVAD.speechSegments, locale: B)
     13. observeIncomingTranscriptions()
     14. incomingTTS.activate()
     15. observeIncomingTTSState()
     16. isIncomingActive = true
  17. isOutgoingActive = true
  18. isStarting = false

stop():
  1. Cancel all observation tasks
  2. await outgoingSTT.deactivate()
  3. await vadFactory.service.deactivate()
  4. audioManager.stopCapture()
  5. await outgoingTTS.deactivate()
  6. await captureService.deactivate()
  7. await incomingVAD.deactivate()
  8. await incomingSTT.deactivate()
  9. await incomingTTS.deactivate()
  10. isOutgoingActive = false; isIncomingActive = false
```

**handleIncomingTranscription** (mirrors existing `handleTranslation` logic):
- Guard: !text.isEmpty, !isIncomingSpeaking (guard from F4.2, see §5.2)
- await incomingTranslationService.translate(text, from: B, to: A)
- incomingTranslation = result
- await incomingTTS.speak(text: result, locale: A)

### 3.3 `TranslationBridge` refactoring

**Change**: Remove `@EnvironmentObject` dependency. Accept model via init parameter.

```swift
// Before (M3):
struct TranslationBridge: View {
    @EnvironmentObject private var model: TranslationBridgeModel
    ...
}

// After (M4):
struct TranslationBridge: View {
    private let model: TranslationBridgeModel
    init(model: TranslationBridgeModel) { self.model = model }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(model.configuration) { session in
                await model.sessionFired(session)
            }
    }
}
```

**TranslateCallApp update**:
```swift
ZStack {
    ContentView()
    TranslationBridge(model: container.outgoingBridgeModel)
    TranslationBridge(model: container.incomingBridgeModel)
}
.environmentObject(container.audioViewModel)
.environmentObject(container.languagePairManager)
// Note: translationBridgeModel removed from environment — no longer needed
```

**AppContainer update**:
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
        audioCoordinator = coordinator
        languagePairManager = lpm
        audioViewModel = AudioViewModel(coordinator: coordinator, languagePairManager: lpm)
    }
}
```

### 3.4 `AVSpeechService` output device routing

**Change**: Add optional `outputDeviceID: AudioDeviceID?` parameter to `AVSpeechService.init()`.

If provided, after `engine.prepare()` and before `engine.start()`, apply:

```swift
private func configureOutputDevice(_ deviceID: AudioDeviceID) throws {
    // engine.outputNode.audioUnit is the underlying AudioUnit for output
    guard let audioUnit = engine.outputNode.audioUnit else {
        throw TTSError.deviceRoutingFailed
    }
    var deviceIDVar = deviceID
    let status = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &deviceIDVar,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard status == noErr else {
        throw TTPError.deviceRoutingFailed
    }
}
```

This must be called **after** `engine.prepare()` and **before** `engine.start()`, and the engine must be stopped when changing devices.

**BlackHole device ID lookup**: `AudioCoordinator` uses the existing `DeviceMonitor` / `AudioManager` device enumeration to find the BlackHole device ID by name (`"BlackHole 2ch"`). If not found, outgoing TTS falls back to system default with a warning.

---

## 4. Modified Components

### 4.1 `AudioViewModel` — evolution

`AudioViewModel` is refactored from owning pipeline logic to **observing `AudioCoordinator`**.

**Removed from AudioViewModel**: all pipeline orchestration methods (`activateSTT`, `observeTranscriptions`, `handleTranslation`, `activateTTS`, `deactivateSTT`, `deactivateTTS`, `observeVADState`).

**Kept in AudioViewModel**: all `@Published` state + `bindAudioManager` + device selection + error alert + UI-specific helpers.

**Added to AudioViewModel**:
```swift
// Incoming pipeline state (NEW)
@Published private(set) var incomingTranscription: String?
@Published private(set) var incomingTranslation: String?
@Published private(set) var isIncomingActive: Bool = false

// Coordinator reference
private let coordinator: AudioCoordinator

// Combine bindings from coordinator (replaces pipeline task observation)
private func bindCoordinator() {
    coordinator.$outgoingTranscription.assign(to: &$latestTranscription)
    coordinator.$outgoingTranslation.assign(to: &$latestTranslation)
    coordinator.$incomingTranscription.assign(to: &$incomingTranscription)
    coordinator.$incomingTranslation.assign(to: &$incomingTranslation)
    coordinator.$isSpeechActive.assign(to: &$isSpeechActive)
    coordinator.$isOutgoingSpeaking.assign(to: &$isSpeaking)
    coordinator.$isIncomingActive.assign(to: &$isIncomingActive)
    coordinator.$errorAlert.assign(to: &$errorAlert)
    coordinator.$isStarting.assign(to: &$isStarting)
}
```

**`toggleCapture` refactor** — delegates entirely to coordinator:
```swift
func toggleCapture() async {
    if isCapturing {
        await coordinator.stop()
    } else {
        do {
            try await coordinator.start(
                languagePair: languagePairManager,
                captureApp: selectedCaptureApp,   // NEW: user-selected SCRunningApplication
                blackHoleDeviceID: resolveBlackHoleDeviceID()
            )
        } catch { /* handle */ }
    }
}
```

### 4.2 `TranscriptionView` — 4-row layout

Add incoming transcription section below the existing two rows:

```swift
// Existing rows:
// Row 1: outgoing transcription (lang A, gray)
// Row 2: outgoing translation (lang B, primary)
// NEW rows:
// Divider
// Row 3: incoming transcription (lang B, gray, labeled "Remote:")
// Row 4: incoming translation (lang A, primary, labeled with arrow)
```

### 4.3 `ContentView` — capture source selector

Add a `Picker` or button to select the audio capture app when the incoming pipeline is enabled. This replaces the manual BlackHole device routing for incoming audio.

---

## 5. Design Decisions & Tradeoffs

### 5.1 Why separate `EnergyVADService` for incoming (not `VADServiceFactory`)

`VADServiceFactory` downloads and initializes Silero VAD (CoreML model). Running two Silero instances simultaneously would double GPU/ANE memory usage (~100 MB model × 2). For MVP:
- Outgoing: uses existing `VADServiceFactory` (Energy → upgrades to Silero)
- Incoming: uses `EnergyVADService` directly (no Silero upgrade)

This reduces peak memory by ~100 MB. If performance testing shows Energy VAD is insufficient for incoming (missed speech), we can add Silero upgrade in a follow-up.

### 5.2 Hook points for F4.2 (Echo Management)

`AudioCoordinator` exposes `isOutgoingSpeaking` and `isIncomingSpeaking` as `@Published` properties. `HalfDuplexManager` (F4.2) will observe these and call back into `AudioCoordinator` via:

```swift
// Called by F4.2 HalfDuplexManager
func suppressIncomingPipeline(_ suppress: Bool)
func suppressOutgoingCapture(_ suppress: Bool)
```

For F4.1, these methods are stubbed (no-ops) — echo management is not active until F4.2.

### 5.3 Language pair change during active session

`AudioCoordinator.updateLanguagePair(_:)` is called when `LanguagePairManager` publishes a change:
1. Stop outgoing STT
2. Re-activate outgoing STT with new locale A
3. Update outgoing translation direction (new `AppleTranslationService` not needed — `AppleTranslationService.translate(from:to:)` accepts parameters per call)
4. Stop incoming STT
5. Re-activate incoming STT with new locale B
6. Update incoming translation direction
7. Reconfigure TTS voices for new locales

This is a brief (~500ms) interruption — acceptable for MVP.

### 5.4 BlackHole device ID resolution

The BlackHole 2ch device ID changes between macOS sessions (dynamic `AudioDeviceID`). Resolution:
- `AudioManager` already enumerates devices by name
- `AudioCoordinator` resolves BlackHole by name at `start()` time
- If not found: outgoing TTS defaults to system output + warning alert

### 5.5 SCStream audio-only configuration

`SCStream` is primarily designed for screen recording. For audio-only capture, we minimize video overhead:
```swift
config.width = 2   // minimum non-zero
config.height = 2
config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps max
config.capturesAudio = true
config.sampleRate = 48000
config.channelCount = 1
config.excludesCurrentProcessAudioForMicrophoneSamples = true
```

This keeps CPU usage minimal — we only receive audio callbacks, video frames are minimal.

### 5.6 `CMSampleBuffer` → `AVAudioPCMBuffer` conversion

Apple's ScreenCaptureKit sample code pattern (from WWDC24):
```swift
func handleAudio(_ buffer: CMSampleBuffer) {
    try? buffer.withAudioBufferList { audioBufferList, blockBuffer in
        guard
            let desc = buffer.formatDescription?.audioStreamBasicDescription,
            let format = AVAudioFormat(standardFormatWithSampleRate: desc.mSampleRate,
                                       channels: desc.mChannelsPerFrame),
            let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                       bufferListNoCopy: audioBufferList.unsafePointer)
        else { return }
        // downsample to 16kHz and yield
    }
}
```

---

## 6. Data Flow Diagrams

### 6.1 Outgoing Pipeline (unchanged from M3, now owned by AudioCoordinator)

```
Microphone
    │ AVAudioEngine tap (48kHz)
    ▼
AudioManager.audioStream16kHz (16kHz mono)
    │
    ▼
VADServiceFactory (Energy → Silero)
    │ speechSegments: AsyncStream<SpeechSegment>
    ▼
AppleSpeechService (STT, locale A)
    │ transcriptionStream: AsyncStream<TranscriptionResult>
    ▼
AppleTranslationService (outgoing, A→B)
    │ translate(text:from:to:) async throws → String
    ▼
AVSpeechService (outgoing, outputDeviceID = BlackHoleID)
    │ audio frames
    ▼
BlackHole 2ch → Zoom/Teams → Remote participant hears B
```

### 6.2 Incoming Pipeline (NEW)

```
Zoom/Teams audio output
    │ SCStream (process: Zoom.app)
    ▼
SystemAudioCaptureService.audioStream16kHz (16kHz mono)
    │
    ▼
EnergyVADService (incoming)
    │ speechSegments: AsyncStream<SpeechSegment>
    ▼
AppleSpeechService (STT, locale B)
    │ transcriptionStream: AsyncStream<TranscriptionResult>
    ▼
AppleTranslationService (incoming, B→A)
    │ translate(text:from:to:) async throws → String
    ▼
AVSpeechService (incoming, outputDeviceID = nil = system speakers)
    │ audio frames
    ▼
Speakers → Local user hears A
```

### 6.3 Language Pair Update Flow

```
User changes A→B to C→D
    │
    ▼
LanguagePairManager.setSourceLanguage(C)
LanguagePairManager.setTargetLanguage(D)
    │ Combine publisher fires
    ▼
AudioCoordinator.updateLanguagePair(_:)
    ├── outgoingSTT.deactivate() → outgoingSTT.activate(locale: C)
    ├── incomingSTT.deactivate() → incomingSTT.activate(locale: D)
    └── (translation direction updated via per-call from/to parameters)
```

---

## 7. Protocol Changes

### 7.1 `VADService` — no change

`EnergyVADService` already conforms. New incoming pipeline creates its own instance directly (no factory needed).

### 7.2 `SpeechRecognizerService` — no change

`AppleSpeechService` already conforms. New incoming instance created with locale B.

### 7.3 `SynthesisService` — `AVSpeechService` init extension

```swift
// New init parameter (optional, backward compatible):
init(outputDeviceID: AudioDeviceID? = nil) throws
```

### 7.4 `TranslationService` — no change

`AppleTranslationService` already accepts `from:to:` per-call — same service type works for both directions.

---

## 8. File Changes Summary

| File | Change |
|------|--------|
| `App/TranslateCallApp.swift` | Add second `TranslationBridge`, remove bridge EnvironmentObject |
| `App/AppContainer.swift` | Add `incomingBridgeModel`, create `AudioCoordinator` |
| `App/TranslationBridge.swift` | Remove `@EnvironmentObject`, add `init(model:)` |
| `Core/Audio/AudioCoordinator.swift` | **NEW** — dual pipeline orchestration |
| `Core/Audio/SystemAudioCaptureService.swift` | **NEW** — SCStream audio capture |
| `Core/TTS/AVSpeechService.swift` | Add `outputDeviceID` param + CoreAudio routing |
| `Features/Main/AudioViewModel.swift` | Refactor to observe `AudioCoordinator` |
| `Features/Main/ContentView.swift` | Add capture app selector UI element |
| `Features/Main/TranscriptionView.swift` | Add incoming transcription rows |
| `Features/Main/StatusBadgeView.swift` | Add incoming pipeline state indicator |

---

## 9. Test Strategy

### Unit Tests (new files)

**`SystemAudioCaptureServiceTests.swift`**:
- Mock `SCStream` — test buffer conversion (`CMSampleBuffer` → `AVAudioPCMBuffer`)
- Test downsampling produces 16kHz output from 48kHz input
- Test permission denied path returns `.permissionDenied` error
- Test `deactivate()` while active does not crash
- `@Suite(.serialized)` — SCStream has global state

**`AudioCoordinatorTests.swift`**:
- Test `start()` activates outgoing pipeline
- Test `start()` skips incoming pipeline when capture unavailable (permission denied)
- Test `stop()` deactivates all services cleanly (no dangling tasks)
- Test `updateLanguagePair()` reconfigures both STT services
- Test fatal error (AudioError.deviceUnavailable) stops both pipelines
- Test non-fatal STT error on outgoing does not stop incoming
- Use mock implementations of `VADService`, `SpeechRecognizerService`, `SynthesisService`, `TranslationService`

**`AVSpeechServiceRoutingTests.swift`**:
- Test that `outputDeviceID = nil` initializes without error
- Test that `outputDeviceID = nonExistentID` throws `TTPError.deviceRoutingFailed`
- (Cannot test real BlackHole routing in CI — manual validation)

### Integration Tests (manual, on device)

| Test | Expected |
|------|----------|
| Speak English, hear Spanish from BlackHole | Outgoing pipeline working |
| Play Spanish in Zoom simulator, hear English from speakers | Incoming pipeline working |
| Change language pair mid-session | Both pipelines update < 500ms |
| Revoke Screen Recording permission | Incoming stops, outgoing continues |

---

## 10. Open Questions Resolved

| OQ | Resolution |
|----|-----------|
| OQ-1 (Mechanism A vs B) | **B (SCStream)** — confirmed primary. Fallback: disable incoming + actionable alert |
| OQ-2 (second BlackHole) | N/A — SCStream eliminates need for virtual device loopback |
| OQ-3 (VAD for incoming) | EnergyVADService only for MVP — Silero upgrade deferred |
| OQ-4 (continuous vs utterance) | Complete utterances only (same as outgoing) |
| OQ-5 (same language detection) | Deferred to M5 |

---

*End of F4.1 Technical Design — Gate 2 Review Pending*
