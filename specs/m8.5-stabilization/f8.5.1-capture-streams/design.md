# F8.5.1 — Capture & Streams — Technical Design

> Status: DRAFT — pending user review (2026-10-03)
> Requirements: `requirements.md` (same folder)

## 1. Overview

The root cause shared by A1, A4 and A5b is **who owns a stream's lifetime**. Today streams are stored properties that the producer either recreates (`AudioManager`) or never recreates (`SystemAudioCaptureService`), and consumers read the property at some moment. The fix is to make the stream the **return value of the start call**. A stream then lives exactly as long as one capture session, and only the producer can end it.

```
 AudioViewModel ── start(captureTarget:) ──► AudioCoordinator
                                               │
            ┌──────────────────────────────────┴───────────────────────────────┐
            │ outgoing                                     incoming            │
            │ let mic = try await audioCapture             let sys = try await │
            │           .startCapture()                    systemCapture       │
            │ outgoingVAD.activate(stream: mic)            .activate(target:)  │
            │                                              incomingVAD         │
            │                                              .activate(stream:sys)│
            │                                              observe(systemCapture│
            │                                                      .events)    │
            └──────────────────────────────────────────────────────────────────┘

 AudioManager (MainActor)                    SystemAudioCaptureService (actor)
  session: SessionAudioStream?                session: SessionAudioStream?
  AVAudioEngine.inputNode ─tap─► MicTap ─►    SCStream ─handler queue─► SystemTap ─►
           (device = selectedInput)   session.yield     (serial)       copy+downsample
                                                        delegate ─► handleStreamStopped
                                                                    → events.yield(.stopped)
```

## 2. Files

```
TranslateCall/Core/Audio/SessionAudioStream.swift        NEW  bounded stream + drop counter
TranslateCall/Core/Audio/CaptureTarget.swift             NEW  CaptureTarget, IncomingStatus, IncomingStopReason, SystemCaptureEvent
TranslateCall/Core/Audio/CoreAudioDevices.swift          NEW  CoreAudio queries moved out of AudioManager (+ default input, set device)
TranslateCall/Core/Audio/AudioManager.swift              CHANGED  returns stream, applies device, hot swap, config change
TranslateCall/Core/Audio/SystemAudioCaptureService.swift CHANGED  target, per-session stream, delegate, owned buffers
TranslateCall/Core/Audio/AudioCoordinator.swift          CHANGED  captureTarget, incomingStatus, retryIncoming, session generation
TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift CHANGED  streams from start calls, events observation, teardown helpers
TranslateCall/Core/Setup/SetupManager.swift              CHANGED  captureTarget from persisted bundle ID
TranslateCall/Features/Main/AudioViewModel.swift         CHANGED  incomingStatus, retryIncoming, device notices
TranslateCall/Features/Main/IncomingStatusBanner.swift   NEW  banner shown in main window + popover
TranslateCall/Features/ContentView.swift, MenuBar/MenuBarPopoverView.swift  CHANGED  host the banner
TranslateCallTests/Mocks/MockAudioCapture.swift          CHANGED
TranslateCallTests/Mocks/MockSystemAudioCapture.swift    CHANGED
TranslateCallTests/Support/FileAudioSource.swift         CHANGED  fresh stream per startCapture
TranslateCallTests/SessionAudioStreamTests.swift         NEW
TranslateCallTests/SystemAudioCaptureServiceTests.swift  CHANGED  owned-memory extraction
TranslateCallTests/AudioCoordinatorTests.swift           CHANGED  re-enabled + new lifecycle tests
TranslateCallTests/Integration/MicCaptureIntegrationTests.swift  NEW  BlackHole input, hot swap
TranslateCallTests/Support/BlackHolePlayer.swift         NEW  plays a fixture into BlackHole
TranslateCallTests/Support/TemporaryAggregateDevice.swift NEW  private aggregate of BlackHole = 2nd input device
.opengrep/rules/swift-audio.yml                          CHANGED  buffer-nocopy-escape → ERROR
specs/m8.5-stabilization/backlog.md                      CHANGED  sub-feature mapping, A1b/A5b
```

The project uses `PBXFileSystemSynchronizedRootGroup`, so new files need no pbxproj edits. The app target builds with `SWIFT_APPROACHABLE_CONCURRENCY` and default MainActor isolation, so helpers that run on audio threads are declared `nonisolated`.

## 3. Components

### 3.1 `SessionAudioStream`

```swift
/// One capture session's 16 kHz stream: bounded, drop-counting, finish-once.
nonisolated final class SessionAudioStream: Sendable {
    let stream: AsyncStream<AVAudioPCMBuffer>
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let label: String
    private let dropped = Atomic<Int>(0)
    private let lastReport = Atomic<UInt64>(0)   // ContinuousClock-independent: DispatchTime.uptimeNanoseconds
    static let capacity = 64

    init(label: String, capacity: Int = SessionAudioStream.capacity)   // makeStream(bufferingPolicy: .bufferingNewest(capacity))
    func yield(_ buffer: AVAudioPCMBuffer)   // on .dropped: increment; log "dropped N" if ≥1 s since lastReport
    func finish()                            // idempotent (continuation.finish is)
    var droppedCount: Int { get }
}
```

- `Atomic` comes from the `Synchronization` module (macOS 15+). It is lock-free, so it is safe on the tap thread (NFR-C-03).
- `yield` is the only thing the audio callbacks call. There is no MainActor hop.

### 3.2 `CaptureTarget` & status types

```swift
enum CaptureTarget: Sendable, Equatable { case app(bundleID: String) }

enum IncomingStopReason: Sendable, Equatable {
    case targetNotFound(bundleID: String), permissionDenied, streamError(String)
    var message: String   // "The call app (us.zoom.xos) is not running", …
}
enum IncomingStatus: Sendable, Equatable { case idle, disabled, starting, active, stopped(IncomingStopReason) }
enum SystemCaptureEvent: Sendable, Equatable { case stopped(IncomingStopReason) }
```

`SystemAudioCaptureError` gains `.targetNotFound(bundleID:)`. A helper `IncomingStopReason(error:)` maps thrown errors: `targetNotFound` → `.targetNotFound`, `permissionDenied` → `.permissionDenied`, anything else → `.streamError(localizedDescription)`.

### 3.3 Protocols

```swift
@MainActor protocol AudioCapture: AnyObject {
    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer>
    func stopCapture()
}

protocol SystemAudioCapture: Actor {
    nonisolated var events: AsyncStream<SystemCaptureEvent> { get }
    func requestPermissionAndLoadApps() async throws -> [SCRunningApplication]   // unchanged, UI only
    func activate(target: CaptureTarget) async throws -> AsyncStream<AVAudioPCMBuffer>
    func deactivate() async
}
```

`isActive` is removed from the protocol (it has no external reader). `startCapture()` while already capturing throws `AudioError.alreadyCapturing`. The coordinator never does that, and returning the existing stream would hand a single-consumer stream to a second consumer.

### 3.4 `AudioManager`

**State (MainActor):** `session: SessionAudioStream?`, `activeDeviceID: AudioDeviceID?`, `@Published deviceNotice: String?`.

**Tap without shared mutable state.** A `MicTap` object holds the session plus that configuration's `AVAudioConverter`, and the tap closure captures it:

```swift
// SAFETY: used only from the AVAudioEngine tap callback, which AVFoundation invokes serially
// for one installed tap; a new MicTap is created for every (re)configuration.
nonisolated final class MicTap: @unchecked Sendable {
    let session: SessionAudioStream; let converter: AVAudioConverter; let onLevel: @Sendable (Float) -> Void
    func process(_ buffer: AVAudioPCMBuffer)   // downsample → session.yield; RMS → onLevel
}
```

This removes `_continuation48`, `_continuation16` and `_converter`, together with their `nonisolated(unsafe)` (REQ-C-41). The `engine` itself stays `nonisolated(unsafe) let`, with a `// SAFETY:` comment: it is only mutated from MainActor, and `configure` is nonisolated only so the tap closure does not inherit `@MainActor` (the existing crash note).

**`configure(device:tap:)`** (nonisolated, called from MainActor with the engine stopped):
1. `removeTap(onBus: 0)`.
2. `CoreAudioDevices.setCurrentDevice(id, on: engine.inputNode.audioUnit)` (`kAudioOutputUnitProperty_CurrentDevice`, same call as `AVSpeechService.swift:86`).
3. Read `inputNode.outputFormat(forBus: 0)` **after** setting the device, because the sample rate may change. Build the converter → `MicTap`.
4. `installTap` → `engine.prepare()` → `engine.start()`.

The engine never touches `mainMixerNode`/`outputNode`, so the input and output devices are not tied together.

**`startCapture()`**: permission check → resolve the device (`selectedInput`, or else the system default via `CoreAudioDevices.defaultInputDeviceID()`) → `session = SessionAudioStream(label: "mic")` → `configure` → `isCapturing = true` → `return session.stream`. If `configure` throws, `session.finish()`, `session = nil`, and rethrow.

**`stopCapture()`**: `removeTap`, `engine.stop()`, `engine.reset()`, `session?.finish()`, `session = nil`, `activeDeviceID = nil`.

**`selectInput(_:)`** (still synchronous `throws`; the `Task { startCapture() }` goes away):
- Not capturing: persist and set `selectedInput`, as today.
- Capturing: `engine.stop()` → `configure(device: new, tap: MicTap(session: same session))`.
  - On failure: `configure(device: previous)` and throw `AudioError.deviceSwitchFailed(name, underlying)`. `selectedInput` stays on the previous device.
  - On success: persist the new device.

**Configuration change.** Observe `.AVAudioEngineConfigurationChange` for `engine`, hopping to MainActor, and ignore it when not capturing:
1. `refreshDevices()`.
2. Choose the target device: `selectedInput` if it is still in `inputDevices`, otherwise the system default.
3. `configure` with the same session.
4. If the device changed, update `selectedInput` (not persisted, so the user's choice comes back next time it is plugged in) and set `deviceNotice = "Microphone '<old>' disconnected — using '<new>'"`.
5. If even the default fails, finish the session. The outgoing VAD loop then ends, and the coordinator is notified (see §3.6, outgoing end).

### 3.5 `SystemAudioCaptureService`

**Long-lived:** `events` (`makeStream`, `.bufferingNewest(8)`) for the life of the service.

**Per activation:** `generation: UInt64`, `session: SessionAudioStream`, `SCStream`, an `SCStreamBridge` (output + delegate) and a `SystemTap`.

```swift
func activate(target: CaptureTarget) async throws -> AsyncStream<AVAudioPCMBuffer> {
    guard captureStream == nil else { throw SystemAudioCaptureError.alreadyActive }
    let content = try await shareableContent()                     // → .permissionDenied
    guard case .app(let bundleID) = target,
          let app = content.applications.first(where: { $0.bundleIdentifier == bundleID })
    else { throw .targetNotFound(bundleID: …) }
    generation &+= 1
    let session = SessionAudioStream(label: "system")
    let tap = try SystemTap(session: session)                      // owns the 48k→16k converter
    let bridge = SCStreamBridge(service: self, generation: generation, tap: tap)
    let stream = SCStream(filter: …, configuration: …, delegate: bridge)
    try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: sampleQueue)  // dedicated serial queue
    try await stream.startCapture()                                // on throw: session.finish(), rethrow .streamFailed
    …store…; return session.stream
}
```

- **Sample path (A2, NFR-C-03).** `bridge.stream(_:didOutputSampleBuffer:of:)` runs on `sampleQueue` and calls `tap.process(sampleBuffer)` **synchronously**. `SystemTap.extractOwnedPCMBuffer` allocates an `AVAudioPCMBuffer` with the sample buffer's format and frame count, then copies each channel from the `AudioBufferList` inside `withAudioBufferList`. It downsamples and calls `session.yield`. There is no `Task` per buffer and no actor hop, and `bufferListNoCopy` is gone. `SystemTap` is `@unchecked Sendable`, with a `// SAFETY:` comment saying it is only used on the serial `sampleQueue`.
- **Delegate (A1b).** `stream(_:didStopWithError:)` → `Task { await service.handleStreamStopped(error, generation: g) }`. The actor ignores the call if `g != generation` or nothing is active, which drops stale callbacks from a previous session. Otherwise it finishes the session, clears the state and yields `.stopped(reason)`. The reason is `.permissionDenied` for `SCStreamError.userDeclined`, and `.streamError(localizedDescription)` for anything else.
- **`deactivate()`.** `stopCapture()` (errors logged), `session.finish()`, clear the state. No event is emitted, because the stop was asked for.

### 3.6 `AudioCoordinator`

**State:**
- `@Published private(set) var incomingStatus: IncomingStatus = .idle`, whose `didSet` updates `@Published private(set) var isIncomingActive`. `AudioViewModel` keeps binding `$isIncomingActive`.
- `private var sessionGeneration: UInt64`, incremented by `start()` and by `stop()`.
- `private var captureTarget: CaptureTarget?`, kept for retry.
- `private var incomingEventsTask: Task<Void, Never>?`.

**`start(captureTarget:blackHoleDeviceID:)`**
- Outgoing: `let mic = try await audioCapture.startCapture()` → `vad.activate(stream: mic)` → the rest as today.
- Then `incomingEventsTask` observes `systemCapture.events` for the whole session.
- Then `await activateIncoming()`.

**`activateIncoming()`** (shared by start and retry):
```
guard let target = captureTarget else { incomingStatus = .disabled; return }
incomingStatus = .starting; let gen = sessionGeneration
do {
  let sys = try await systemCapture.activate(target: target)
  guard gen == sessionGeneration else { await systemCapture.deactivate(); return }      // REQ-C-35
  create VAD → activate(stream: sys) → STT → TTS   (same order as today; re-check gen after each await,
                                                    on mismatch tear down what was created and return)
  incomingStatus = .active
} catch {
  await teardownIncomingServices(); await systemCapture.deactivate()
  incomingStatus = .stopped(IncomingStopReason(error: error))
}
```

**`retryIncoming()`**: `guard case .stopped = incomingStatus else { return }`. Then `incomingStatus = .starting` synchronously, so a second call is a no-op (REQ-C-34), and `Task { await activateIncoming() }`. `AudioViewModel.retryIncoming()` calls it.

**Event `.stopped(reason)`**: if `incomingStatus == .active`, run `teardownIncomingServices()` (deactivate and nil the VAD, STT and TTS, cancel `incomingTasks`), set `isIncomingSpeaking = false` (which releases half-duplex) and `incomingStatus = .stopped(reason)`.

**`stop()`**:
- `sessionGeneration &+= 1` and cancel `incomingEventsTask`.
- Tear down as today: `systemCapture.deactivate()` finishes the stream.
- `incomingStatus = .idle`.

**Outgoing end.** If the mic session finishes without a stop, the VAD loop simply ends. In this feature that happens only when even the default device fails (§3.4). `AudioManager.deviceNotice` already surfaces it. Turning it into a coordinator status is out of scope (YAGNI). The notice says capture stopped.

### 3.7 `SetupManager` & UI

- `var captureTarget: CaptureTarget?`: the persisted `captureAppBundleKey`, non-empty → `.app(bundleID:)`. It is independent of whether that app is in `availableCaptureApps` (REQ-C-22). The picker keeps working with `SCRunningApplication` for display.
- `AudioViewModel.startPipeline()` passes `setupManager.captureTarget`. The view model binds `coordinator.$incomingStatus` and maps `audioManager.$deviceNotice` → `errorAlert` (title "Microphone"), as `selectInput` already does for errors.
- `IncomingStatusBanner(status:onRetry:)`: one row with an SF Symbol and text.
  - `.disabled`: "Incoming off — choose the call app in Setup".
  - `.stopped(r)`: "Incoming stopped: \(r.message)" plus a **Retry** button.
  - `.starting`: "Connecting to call audio…".
  - Hidden otherwise.
  - Shown above `TranscriptionView` in `ContentView` and in `MenuBarPopoverView`.

## 4. Error handling summary

| Situation | Result |
|-----------|--------|
| Mic permission denied / no input | `startCapture` throws → fatal alert (unchanged) |
| Selected mic fails at start | throws `engineStartFailed(…)` → fatal alert naming the device |
| Mic switch fails mid-session | revert to previous device, alert "Could not use <mic>", session continues |
| Selected mic unplugged | fall back to default, notice, session continues |
| No capture target | `incomingStatus = .disabled`, outgoing runs |
| Target app not running at start/retry | `.stopped(.targetNotFound)` + Retry |
| Screen Recording denied | `.stopped(.permissionDenied)` + Retry |
| SCStream stops with error mid-session | `.stopped(.streamError)` + Retry, outgoing runs |
| Stop during activation | activation tears itself down, `.idle` |
| Consumer slower than capture | oldest buffers dropped, counted, logged ≤ 1/s |

## 5. Testing

### 5.1 Mocks

- **`MockAudioCapture`**
  - `startCapture()` returns a **new** stream each call (`makeStream`), stores the continuation, and increments `startCount`.
  - `injectBuffer` yields to the current session's stream, and `stopCapture` finishes it.
  - `simulateDeviceSwitch()` does nothing to the stream (models REQ-C-11).
- **`MockSystemAudioCapture`**
  - `activate(target:)` records `activatedTargets` and returns a new stream.
  - `throwOnActivate` makes activation throw.
  - `activationGate`: an optional `CheckedContinuation` that suspends `activate` until the test releases it. The stop-during-retry test uses it.
  - `emit(_ event:)` yields on `events`; `injectBuffer` feeds the current stream.
- **`FileAudioSource`**: creates its stream inside `startCapture()` and returns it. The integration helpers use the returned stream.

### 5.2 Unit tier

| Test | Pins |
|------|------|
| `SessionAudioStream`: finish ends iteration; 70 yields without a consumer → 64 delivered, `droppedCount == 6`; finish twice is safe | REQ-C-05/06 |
| Coordinator Start → Stop → Start: second `activate` returns a different stream; a buffer injected after restart reaches the incoming VAD | A1, REQ-C-03 |
| The 5 tests re-enabled with `.app(bundleID: "com.test.call")` | T1 |
| `captureTarget == nil` → `.disabled`, no `activate` call | D-3 |
| Activation throws `targetNotFound` → `.stopped(.targetNotFound)`, outgoing active | REQ-C-21/31 |
| `emit(.stopped(.streamError))` while active → incoming services deactivated, `isIncomingSpeaking == false`, `.stopped`, outgoing active | REQ-C-33 |
| `retryIncoming()` after stop event → `.active`, new stream; two calls in a row → one `activate` | REQ-C-34 |
| `stop()` while `activate` is suspended on the gate → after release: `deactivate` called, no incoming services alive, `.idle` | REQ-C-35 |
| Stale `.stopped` event after `stop()` → status stays `.idle` | REQ-C-32 |
| Mic device switch (mock) → outgoing VAD `activateCalled` once; buffers after the switch reach it | A5b |
| `SystemTap.extractOwnedPCMBuffer` on a synthetic `CMSampleBuffer` (sine wave): after the sample buffer is released, the samples are still equal to the sine | A2, REQ-C-40 |
| `IncomingStopReason(error:)` mapping | REQ-C-31 |

### 5.3 Integration tier (`MicCaptureIntegrationTests`, in `extension IntegrationTests`)

Prerequisites, which fail rather than skip (REQ-W-23): BlackHole 2ch present, and the Microphone permission for the test host.

- **`BlackHolePlayer`**: its own `AVAudioEngine` whose output device is set to BlackHole (same CoreAudio call as the TTS services). It plays a fixture WAV in a loop.
- **`TemporaryAggregateDevice`**: `AudioHardwareCreateAggregateDevice` with `kAudioAggregateDeviceIsPrivateKey = 1` and BlackHole as the only sub-device, destroyed in `deinit`. It gives a **second, distinct input device** that hears the same audio. The Mac mini has no built-in microphone, and the tests must never depend on microphone content (REQ-W-22). It is created before `AudioManager` is initialised, so it appears in `inputDevices`.

Tests:
1. **Selected device is used (A5).** `selectedInput = BlackHole` → `startCapture` → `CoreAudioDevices.currentDevice(of: engine.inputNode)` == BlackHole ID → play the fixture → within 3 s, a buffer with RMS > −50 dBFS arrives.
2. **Hot swap (A5b, NFR-C-01).** Start on the aggregate → play → receive audio → `selectInput(BlackHole)` on the **same iterator** → audio keeps arriving; the gap between the last buffer before the switch and the first one after is ≤ 500 ms; `CurrentDevice` == BlackHole.
3. **Stop → Start (A1-mic).** Stop → Start → the new stream delivers audio; the old stream's iterator has ended.

SCStream and the real system-audio path stay manual (Screen Recording permission plus a real app), as the existing manual test does.

### 5.4 Manual checklist

Recorded in `tasks.md` with date and result:
- Zoom or FaceTime: Start → Stop → Start, incoming still translates.
- Quit the call app mid-session: banner "stopped", outgoing still works.
- Reopen the app → Retry → incoming translates.
- Unplug the selected USB mic or AirPods mid-session: falls back to the default with a notice, outgoing continues.
- Start with the saved call app not running: banner `targetNotFound` → open the app → Retry works.

### 5.5 Static analysis

- `buffer-nocopy-escape` → `severity: ERROR` (the last occurrence is removed; REQ-W-51).
- `asyncstream-unbounded` stays WARNING, because Core/TTS occurrences remain until F8.5.2. Its findings under `Core/Audio` must be zero.
- `just scan` must show no `nonisolated-unsafe-justified` / `asyncstream-force-unwrap` findings in `TranslateCall/Core/Audio/`.

## 6. Risks

| Risk | Mitigation |
|------|------------|
| Setting `CurrentDevice` on `inputNode` makes `engine.start()` fail when the input and output devices differ | The capture engine never instantiates `outputNode`/`mainMixerNode`. Integration test 1 runs with BlackHole input and a different system output. |
| `AVAudioEngineConfigurationChange` also fires on our own `configure` | The handler compares the active device and format and ignores no-op changes. It runs on MainActor after `configure` has returned. |
| A private aggregate device does not show up in `inputDevices` | The helper calls the same CoreAudio enumeration directly. If it is absent, the test fails with a clear message, and the design falls back to a manual hot-swap check. |
| `Atomic` adds the `Synchronization` import | It is a system module on macOS 15+, so no new dependency. |
