# F8.5.1 Capture & Streams Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Both capture paths (mic → outgoing, ScreenCaptureKit → incoming) survive Stop → Start, a mic change mid-session, an unplugged device, the call app quitting and stream errors, with bounded, memory-safe streams and a testable incoming path.

**Architecture:** Each capture session's stream is the **return value** of `startCapture()` / `activate(target:)`, wrapped in a bounded `SessionAudioStream`; the producer is its only owner. Mic device selection and hot swap are internal to `AudioManager` (same stream, engine reconfigured). The incoming path takes a value-type `CaptureTarget`, reports failures through a long-lived `events` stream, and the coordinator publishes `incomingStatus` with a Retry action.

**Tech Stack:** Swift 6 (app target: default MainActor isolation + approachable concurrency), AVFoundation/AVAudioEngine, CoreAudio HAL, ScreenCaptureKit, `Synchronization.Atomic`, Swift Testing, `just`, opengrep.

**Spec:** `specs/m8.5-stabilization/f8.5.1-capture-streams/requirements.md`, `specs/m8.5-stabilization/f8.5.1-capture-streams/design.md`

## Global Constraints

- Work on branch `feat/f8.5.1-capture-streams` created from an up-to-date `main` (after the spec PR merges). Never commit to `main`; integrate via PR; `just pr` must pass before the PR.
- Commits: Conventional Commits; end every message with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```
- `SWIFT_VERSION = 6.0`, `MACOSX_DEPLOYMENT_TARGET = 15.0`. App target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: any type or helper used from audio threads or actors is declared `nonisolated` (project convention: `nonisolated enum …`, `nonisolated final class …`).
- New files are picked up automatically (`PBXFileSystemSynchronizedRootGroup`) — never hand-edit `project.pbxproj`.
- Streams: create with `AsyncStream.makeStream(of:bufferingPolicy:)`; production capture streams use `.bufferingNewest(64)` via `SessionAudioStream` (REQ-C-05/06). No `cont!`.
- Every `nonisolated(unsafe)` kept in a touched file carries a `// SAFETY:` comment on the line above (REQ-C-41).
- Audio callbacks (tap block, SCStream sample handler) never `await`, never hop to MainActor per buffer except the existing level-meter `Task { @MainActor }`, never take locks (NFR-C-03).
- Unit tests never touch real hardware streams, MLX models, network or Screen Recording; integration tests fail (never skip) on a missing prerequisite via `requirePrerequisite` (REQ-W-23).
- No fixed sleeps in async tests: wait on a condition with `waitUntil` (added in Task 2) or `finish(_:within:)`.
- Run a single unit suite: `just test-only <SuiteTypeName> [...]`. Full unit tier: `just test`. Integration tier: `just test-integration`.

## Review Focus

- **SCStream delivers a non-Float32 or interleaved sample buffer** → `SystemTap.extractOwnedPCMBuffer` returns `nil` (buffer dropped, logged), never copies garbage (pinned in Task 4 test `rejectsNonFloatFormat`).
- **The call app's stream dies while incoming is still `.starting`** → status ends `.stopped(reason)`, not `.active` on a dead stream (pinned in Task 5 test `stopEventDuringStartingEndsStopped`).
- **User clicks Retry twice / Stop during Retry** → one activation; Stop leaves no incoming service alive and status `.idle` (pinned in Task 5 tests `doubleRetryActivatesOnce`, `stopDuringActivationTearsDown`).
- **Mic switch to a device that fails to start** → previous device restored, session stream still alive, picker shows the previous device (pinned in Task 6 `switchFailureKeepsPreviousDevice` via an injected failing configure, and the VM resync in Task 6 Step 5).
- **`AVAudioEngineConfigurationChange` fired by our own reconfiguration** → ignored (no notice, no loop) (pinned in Task 6 `configChangeForActiveDeviceIsIgnored`).

---

### Task 1: `SessionAudioStream` and capture status types

**Files:**
- Create: `TranslateCall/Core/Audio/SessionAudioStream.swift`
- Create: `TranslateCall/Core/Audio/CaptureTarget.swift`
- Modify: `TranslateCall/Core/Audio/SystemAudioCaptureService.swift:13-29` (error enum)
- Test: `TranslateCallTests/SessionAudioStreamTests.swift`, `TranslateCallTests/CaptureTargetTests.swift`
- Create: `TranslateCallTests/Support/PCMBuffers.swift`

**Interfaces:**
- Produces:
  - `nonisolated final class SessionAudioStream: Sendable { static let capacity = 64; let stream: AsyncStream<AVAudioPCMBuffer>; init(label: String, capacity: Int = SessionAudioStream.capacity); func yield(_ buffer: AVAudioPCMBuffer); func finish(); var droppedCount: Int { get } }`
  - `nonisolated enum CaptureTarget: Sendable, Equatable { case app(bundleID: String) }`
  - `nonisolated enum IncomingStopReason: Sendable, Equatable { case targetNotFound(bundleID: String), permissionDenied, streamError(String); init(error: Error); var message: String }`
  - `nonisolated enum IncomingStatus: Sendable, Equatable { case idle, disabled, starting, active, stopped(IncomingStopReason) }`
  - `nonisolated enum SystemCaptureEvent: Sendable, Equatable { case stopped(IncomingStopReason) }`
  - `SystemAudioCaptureError` gains `.targetNotFound(bundleID: String)` and `.alreadyActive`.
  - Test helper `func makePCMBuffer(frames: AVAudioFrameCount = 160, sampleRate: Double = 16_000, fill: Float = 0) -> AVAudioPCMBuffer`

- [ ] **Step 1: Write the test helper and failing tests**

`TranslateCallTests/Support/PCMBuffers.swift`:
```swift
import AVFoundation

/// Mono Float32 buffer whose every sample is `fill`; `frameLength == frames`.
func makePCMBuffer(frames: AVAudioFrameCount = 160, sampleRate: Double = 16_000, fill: Float = 0) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    if let data = buffer.floatChannelData?[0] {
        for i in 0..<Int(frames) { data[i] = fill }
    }
    return buffer
}
```

`TranslateCallTests/SessionAudioStreamTests.swift`:
```swift
import AVFoundation
import Testing
@testable import TranslateCall

@Suite("SessionAudioStream")
struct SessionAudioStreamTests {

    @Test("finish ends iteration after delivering pending buffers")
    func finishEndsIteration() async {
        let session = SessionAudioStream(label: "test")
        session.yield(makePCMBuffer())
        session.finish()
        var count = 0
        for await _ in session.stream { count += 1 }
        #expect(count == 1)
    }

    @Test("overflow keeps the newest 64 buffers and counts the dropped ones")
    func overflowDropsOldest() async {
        let session = SessionAudioStream(label: "test")
        for i in 1...70 { session.yield(makePCMBuffer(frames: AVAudioFrameCount(i))) }
        session.finish()
        var lengths: [AVAudioFrameCount] = []
        for await buffer in session.stream { lengths.append(buffer.frameLength) }
        #expect(lengths.count == 64)
        #expect(lengths.first == 7)
        #expect(lengths.last == 70)
        #expect(session.droppedCount == 6)
    }

    @Test("finish twice and yield after finish are safe and not counted as drops")
    func finishIsIdempotent() async {
        let session = SessionAudioStream(label: "test")
        session.finish()
        session.finish()
        session.yield(makePCMBuffer())
        var count = 0
        for await _ in session.stream { count += 1 }
        #expect(count == 0)
        #expect(session.droppedCount == 0)
    }
}
```

`TranslateCallTests/CaptureTargetTests.swift`:
```swift
import Foundation
import Testing
@testable import TranslateCall

@Suite("IncomingStopReason")
struct IncomingStopReasonTests {

    @Test("maps capture errors to stop reasons")
    func mapsErrors() {
        #expect(IncomingStopReason(error: SystemAudioCaptureError.targetNotFound(bundleID: "us.zoom.xos"))
                == .targetNotFound(bundleID: "us.zoom.xos"))
        #expect(IncomingStopReason(error: SystemAudioCaptureError.permissionDenied) == .permissionDenied)
        let other = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        #expect(IncomingStopReason(error: other) == .streamError("boom"))
    }

    @Test("every reason has a non-empty user message naming the cause")
    func messages() {
        #expect(IncomingStopReason.targetNotFound(bundleID: "us.zoom.xos").message.contains("us.zoom.xos"))
        #expect(IncomingStopReason.permissionDenied.message.contains("Screen Recording"))
        #expect(IncomingStopReason.streamError("boom").message.contains("boom"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test-only SessionAudioStreamTests IncomingStopReasonTests`
Expected: build FAILS — `cannot find 'SessionAudioStream' in scope`, `type 'SystemAudioCaptureError' has no member 'targetNotFound'`.

- [ ] **Step 3: Implement**

`TranslateCall/Core/Audio/SessionAudioStream.swift`:
```swift
import AVFoundation
import os
import Synchronization

nonisolated private let logger = Logger(subsystem: "TranslateCall", category: "SessionAudioStream")

/// One capture session's 16 kHz stream (F8.5.1 REQ-C-01/05): bounded, drop-counting, finish-once.
///
/// The producer owns it: create one per capture session, `yield` from the audio callback,
/// `finish()` when the session ends. `yield` never blocks or hops actors, so it is safe on
/// AVAudioEngine tap and SCStream sample-handler threads (NFR-C-03).
nonisolated final class SessionAudioStream: Sendable {
    static let capacity = 64

    let stream: AsyncStream<AVAudioPCMBuffer>
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let label: String
    private let dropped = Atomic<Int>(0)
    private let lastReportNanos = Atomic<UInt64>(0)

    init(label: String, capacity: Int = SessionAudioStream.capacity) {
        self.label = label
        (stream, continuation) = AsyncStream.makeStream(
            of: AVAudioPCMBuffer.self, bufferingPolicy: .bufferingNewest(capacity)
        )
    }

    var droppedCount: Int { dropped.load(ordering: .relaxed) }

    func yield(_ buffer: AVAudioPCMBuffer) {
        guard case .dropped = continuation.yield(buffer) else { return }
        let total = dropped.add(1, ordering: .relaxed).newValue
        let now = DispatchTime.now().uptimeNanoseconds
        let last = lastReportNanos.load(ordering: .relaxed)
        guard now &- last >= 1_000_000_000,
              lastReportNanos.compareExchange(expected: last, desired: now, ordering: .relaxed).exchanged
        else { return }
        logger.warning("\(self.label, privacy: .public): consumer too slow — \(total) buffers dropped so far")
    }

    func finish() {
        continuation.finish()
    }
}
```

`TranslateCall/Core/Audio/CaptureTarget.swift`:
```swift
import Foundation

/// What the incoming pipeline captures (F8.5.1 REQ-C-20). A value type so the coordinator
/// and its tests never need an `SCRunningApplication`.
nonisolated enum CaptureTarget: Sendable, Equatable {
    case app(bundleID: String)
}

/// Why incoming capture is not running (REQ-C-31).
nonisolated enum IncomingStopReason: Sendable, Equatable {
    case targetNotFound(bundleID: String)
    case permissionDenied
    case streamError(String)

    init(error: Error) {
        switch error {
        case SystemAudioCaptureError.targetNotFound(let bundleID):
            self = .targetNotFound(bundleID: bundleID)
        case SystemAudioCaptureError.permissionDenied:
            self = .permissionDenied
        default:
            self = .streamError(error.localizedDescription)
        }
    }

    var message: String {
        switch self {
        case .targetNotFound(let bundleID):
            return "The call app (\(bundleID)) is not running."
        case .permissionDenied:
            return "Screen Recording permission is required to hear the call."
        case .streamError(let detail):
            return "Call audio capture failed: \(detail)"
        }
    }
}

/// Incoming pipeline status published by `AudioCoordinator` (REQ-C-30).
nonisolated enum IncomingStatus: Sendable, Equatable {
    case idle
    case disabled
    case starting
    case active
    case stopped(IncomingStopReason)
}

/// Out-of-band events from `SystemAudioCapture` (REQ-C-32).
nonisolated enum SystemCaptureEvent: Sendable, Equatable {
    case stopped(IncomingStopReason)
}
```

In `SystemAudioCaptureService.swift`, replace the error enum (lines 13-29) with:
```swift
nonisolated enum SystemAudioCaptureError: LocalizedError {
    case permissionDenied
    case noDisplayAvailable
    case targetNotFound(bundleID: String)
    case alreadyActive
    case streamFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is required to capture remote audio. "
                + "Enable it in System Settings > Privacy > Screen Recording."
        case .noDisplayAvailable:
            return "No display available for audio capture."
        case .targetNotFound(let bundleID):
            return "The call app (\(bundleID)) is not running."
        case .alreadyActive:
            return "System audio capture is already active."
        case .streamFailed(let error):
            return "Audio capture stream failed: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test-only SessionAudioStreamTests IncomingStopReasonTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/Audio/SessionAudioStream.swift TranslateCall/Core/Audio/CaptureTarget.swift \
        TranslateCall/Core/Audio/SystemAudioCaptureService.swift TranslateCallTests/SessionAudioStreamTests.swift \
        TranslateCallTests/CaptureTargetTests.swift TranslateCallTests/Support/PCMBuffers.swift
git commit -m "feat(audio): bounded SessionAudioStream and capture status types (F8.5.1)"
```

---

### Task 2: Streams returned by the start calls (protocol migration, A1, A4, T1)

**Files:**
- Create: `TranslateCall/Core/Audio/MicTap.swift`, `TranslateCall/Core/Audio/SyncBox.swift`
- Modify: `TranslateCall/Core/Audio/AudioManager.swift` (protocol 13-22, streams 48-62, `recreateStreams` 140-150, capture 152-185, `selectInput` 189-198, `configureEngine`/`handleBuffer`/`downsample`/`computeRMS` 216-309)
- Modify: `TranslateCall/Core/Audio/AudioError.swift`
- Modify: `TranslateCall/Core/Audio/SystemAudioCaptureService.swift` (protocol 31-51, stored state 63-84, `activate` 101-175, `deactivate` 179-191, `handleCapturedBuffer` 195-198)
- Modify: `TranslateCall/Core/Audio/AudioCoordinator.swift:133-148,150-185`
- Modify: `TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift:16-99`
- Modify: `TranslateCall/Core/Setup/SetupManager.swift` (add `captureTarget`)
- Modify: `TranslateCall/Features/Main/AudioViewModel.swift:218-225`
- Modify: `TranslateCallTests/Mocks/MockAudioCapture.swift`, `TranslateCallTests/Mocks/MockSystemAudioCapture.swift`, `TranslateCallTests/Mocks/MockVADService.swift`
- Modify: `TranslateCallTests/Support/FileAudioSource.swift`, `TranslateCallTests/Integration/Prerequisites.swift:66-86`, `TranslateCallTests/Support/AsyncTestHelpers.swift`
- Test: `TranslateCallTests/AudioCoordinatorTests.swift`, `TranslateCallTests/SetupManagerTests.swift`, `TranslateCallTests/SystemAudioCaptureServiceTests.swift`

**Interfaces:**
- Consumes: `SessionAudioStream`, `CaptureTarget`, `SystemAudioCaptureError.targetNotFound/.alreadyActive` (Task 1), `makePCMBuffer` (Task 1).
- Produces:
  - `@MainActor protocol AudioCapture: AnyObject { func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer>; func stopCapture() }`
  - `protocol SystemAudioCapture: Actor { func requestPermissionAndLoadApps() async throws -> [SCRunningApplication]; func activate(target: CaptureTarget) async throws -> AsyncStream<AVAudioPCMBuffer>; func deactivate() async }`
  - `AudioError.alreadyCapturing`
  - `nonisolated final class SyncBox<T>: @unchecked Sendable { var value: T; init(_ value: T) }` (moved out of AudioManager)
  - `nonisolated final class MicTap: @unchecked Sendable { init?(session: SessionAudioStream, inputFormat: AVAudioFormat, onLevel: @escaping @Sendable (Float) -> Void); func process(_ buffer: AVAudioPCMBuffer); static func rms(_ buffer: AVAudioPCMBuffer) -> Float }`
  - `AudioCoordinator.start(captureTarget: CaptureTarget? = nil, blackHoleDeviceID: AudioDeviceID? = nil) async`
  - `SetupManager.captureTarget: CaptureTarget?`
  - `SystemAudioCaptureService.isActive: Bool` (actor-isolated, `captureStream != nil`)
  - Mocks: `MockAudioCapture.startCount: Int`, `MockSystemAudioCapture.activatedTargets: [CaptureTarget]`, `.deactivateCount: Int`, `MockVADService.activateCount: Int`, `.receivedBufferCount: Int`
  - `func waitUntil(timeout: Duration = .seconds(2), isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async -> Bool`

- [ ] **Step 1: Update mocks and helpers to the new API (test side first)**

`TranslateCallTests/Support/AsyncTestHelpers.swift` — append:
```swift
/// Polls `condition` until it holds or `timeout` elapses; returns the final value.
/// Use instead of fixed sleeps: it waits on the observable outcome, not on a guessed delay.
func waitUntil(
    timeout: Duration = .seconds(2),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
```

Replace `TranslateCallTests/Mocks/MockAudioCapture.swift` body:
```swift
import AVFoundation
@testable import TranslateCall

/// Test double for `AudioCapture`: a fresh stream per `startCapture()`, like `AudioManager`.
@MainActor
final class MockAudioCapture: AudioCapture {
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    private(set) var startCount = 0
    var startCaptureCalled: Bool { startCount > 0 }
    var stopCaptureCalled = false
    var throwOnStartCapture: Error?

    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
        if let error = throwOnStartCapture { throw error }
        startCount += 1
        let (stream, continuation) = AsyncStream.makeStream(
            of: AVAudioPCMBuffer.self, bufferingPolicy: .bufferingNewest(SessionAudioStream.capacity)
        )
        self.continuation = continuation
        return stream
    }

    func stopCapture() {
        stopCaptureCalled = true
        continuation?.finish()
        continuation = nil
    }

    /// Feeds a buffer into the current session's stream (simulated mic audio).
    func injectBuffer(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(buffer)
    }
}
```

Replace `TranslateCallTests/Mocks/MockSystemAudioCapture.swift` body:
```swift
import AVFoundation
import ScreenCaptureKit
@testable import TranslateCall

/// Test double for `SystemAudioCapture`: a fresh stream per `activate(target:)`.
actor MockSystemAudioCapture: SystemAudioCapture {
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    var requestPermissionCalled = false
    private(set) var activatedTargets: [CaptureTarget] = []
    var activateCalled: Bool { !activatedTargets.isEmpty }
    private(set) var deactivateCount = 0
    var deactivateCalled: Bool { deactivateCount > 0 }

    var throwOnRequestPermission: Error?
    var throwOnActivate: Error?
    var appsToReturn: [SCRunningApplication] = []

    func requestPermissionAndLoadApps() async throws -> [SCRunningApplication] {
        requestPermissionCalled = true
        if let error = throwOnRequestPermission { throw error }
        return appsToReturn
    }

    func activate(target: CaptureTarget) async throws -> AsyncStream<AVAudioPCMBuffer> {
        if let error = throwOnActivate { throw error }
        activatedTargets.append(target)
        let (stream, continuation) = AsyncStream.makeStream(
            of: AVAudioPCMBuffer.self, bufferingPolicy: .bufferingNewest(SessionAudioStream.capacity)
        )
        self.continuation = continuation
        return stream
    }

    func deactivate() async {
        deactivateCount += 1
        continuation?.finish()
        continuation = nil
    }

    /// Feeds a buffer into the current session's stream (simulated remote audio).
    func injectBuffer(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(buffer)
    }
}
```

In `TranslateCallTests/Mocks/MockVADService.swift`, make the mock consume its input like the real VADs do (cancelling the consumer terminates the stream — exactly what exposed A1):
```swift
    // Call tracking
    private(set) var activateCount = 0
    var activateCalled: Bool { activateCount > 0 }
    var deactivateCalled = false
    var throwOnActivate: Error?
    private(set) var receivedBufferCount = 0
    private var consumeTask: Task<Void, Never>?
```
and replace `activate`/`deactivate`:
```swift
    func activate(stream: AsyncStream<AVAudioPCMBuffer>) async throws {
        if let error = throwOnActivate { throw error }
        activateCount += 1
        consumeTask = Task {
            for await _ in stream { receivedBufferCount += 1 }
        }
    }

    func deactivate() async {
        deactivateCalled = true
        consumeTask?.cancel()
        consumeTask = nil
        speechContinuation?.finish()
        stateContinuation?.finish()
    }
```

Replace in `TranslateCallTests/Support/FileAudioSource.swift` the stored stream and capture methods:
```swift
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private let samples: [Float]
    private let realtime: Bool
    private var task: Task<Void, Never>?

    init(url: URL, realtime: Bool = true, trailingSilence: TimeInterval = 1.5) throws {
        samples = try Self.decode16kMono(url) + Array(repeating: 0, count: Int(trailingSilence * Self.sampleRate))
        self.realtime = realtime
    }

    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
        let (stream, cont) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self, bufferingPolicy: .unbounded)
        continuation = cont
        let samples = samples, realtime = realtime
        task = Task.detached {
            // … unchanged loop body (uses `cont`) …
        }
        return stream
    }

    func stopCapture() {
        task?.cancel()
        continuation?.finish()
    }
```
(remove the `let audioStream16kHz` and `let continuation` stored properties; the detached loop body is unchanged.)

In `TranslateCallTests/Integration/Prerequisites.swift` (`firstTranscript`): delete line 70 `try await vad.activate(stream: source.audioStream16kHz)` and replace line 85 `try await source.startCapture()` with:
```swift
    let audio = try await source.startCapture()
    try await vad.activate(stream: audio)
```
(`vad.speechSegments` is a `nonisolated let`, so the tee set up before activation keeps working.)

- [ ] **Step 2: Write the failing coordinator, setup and service tests**

In `TranslateCallTests/AudioCoordinatorTests.swift`:
1. Add at file scope: `private let callTarget = CaptureTarget.app(bundleID: "com.test.call")`.
2. In the five tests carrying `.disabled("F8.5.1: …")` (`startActivatesIncoming`, `startSkipsIncomingOnPermissionDenied`, `stopDeactivatesAll`, `updateLanguagePairReconfigures`, `nonFatalOutgoingSTTErrorKeepsIncomingAlive`): delete the `.disabled(...)` trait and change `await coordinator.start()` to `await coordinator.start(captureTarget: callTarget)`.
3. In `startIsIdempotent` replace the body's counting with:
```swift
        await coordinator.start()
        await coordinator.start()  // should be a no-op
        #expect(mocks.mockAudioCapture.startCount == 1)
```
4. Add:
```swift
    @Test("Stop → Start hands the incoming VAD a fresh, live stream (A1)")
    func restartGivesFreshIncomingStream() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)

        await coordinator.start(captureTarget: callTarget)
        await coordinator.stop()
        await coordinator.start(captureTarget: callTarget)
        await mocks.mockSystemCapture.injectBuffer(makePCMBuffer())

        #expect(await waitUntil { await mocks.mockIncomingVAD.receivedBufferCount == 1 })
        #expect(await mocks.mockSystemCapture.activatedTargets == [callTarget, callTarget])
        #expect(coordinator.isIncomingActive)
    }

    @Test("Stop → Start hands the outgoing VAD a fresh, live mic stream")
    func restartGivesFreshMicStream() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)

        await coordinator.start()
        await coordinator.stop()
        await coordinator.start()
        mocks.mockAudioCapture.injectBuffer(makePCMBuffer())

        #expect(await waitUntil { await mocks.mockVADFactory.receivedBufferCount == 1 })
        #expect(mocks.mockAudioCapture.startCount == 2)
    }

    @Test("start() passes the capture target to system capture")
    func startPassesCaptureTarget() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        #expect(await mocks.mockSystemCapture.activatedTargets == [callTarget])
    }
```

In `TranslateCallTests/SetupManagerTests.swift` add:
```swift
    @Test("captureTarget comes from the persisted bundle ID, even if the app is not running")
    func captureTargetFromPersistedBundleID() {
        let defaults = makeDefaults()
        defaults.set("us.zoom.xos", forKey: "tlk.captureApp.bundleID")
        let mgr = SetupManager(defaults: defaults)
        #expect(mgr.captureTarget == .app(bundleID: "us.zoom.xos"))
    }

    @Test("captureTarget is nil when no app is persisted")
    func captureTargetNilWhenUnset() {
        let defaults = makeDefaults()
        defaults.set("", forKey: "tlk.captureApp.bundleID")
        #expect(SetupManager(defaults: defaults).captureTarget == nil)
        #expect(SetupManager(defaults: makeDefaults()).captureTarget == nil)
    }
```

In `TranslateCallTests/SystemAudioCaptureServiceTests.swift`, change the two `isActive` tests to `#expect(await service.isActive == false)`.

- [ ] **Step 3: Run tests to verify they fail**

Run: `just test-only AudioCoordinatorTests SetupManagerTests SystemAudioCaptureServiceTests`
Expected: build FAILS — `startCapture()` result type mismatch in mocks vs protocol, `extra argument 'captureTarget'`, `value of type 'SetupManager' has no member 'captureTarget'`.

- [ ] **Step 4: Implement `MicTap` and the new `AudioManager` stream lifecycle**

`TranslateCall/Core/Audio/MicTap.swift`:
```swift
import Accelerate
import AVFoundation

/// Per-configuration mic tap: downsamples to 16 kHz mono and yields into the session stream.
///
// SAFETY: AVAudioEngine invokes an installed tap block serially; a new MicTap is created for
// every (re)configuration and only `process` touches `converter`, so it is never used concurrently.
nonisolated final class MicTap: @unchecked Sendable {
    private let session: SessionAudioStream
    private let converter: AVAudioConverter
    private let onLevel: @Sendable (Float) -> Void

    init?(session: SessionAudioStream, inputFormat: AVAudioFormat, onLevel: @escaping @Sendable (Float) -> Void) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target)
        else { return nil }
        self.session = session
        self.converter = converter
        self.onLevel = onLevel
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        if let converted = downsample(buffer) {
            session.yield(converted)
        }
        onLevel(Self.rms(buffer))
    }

    private func downsample(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        let provided = SyncBox(false)
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if provided.value { status.pointee = .noDataNow; return nil }
            provided.value = true
            status.pointee = .haveData
            return buffer
        }
        return conversionError == nil && output.frameLength > 0 ? output : nil
    }

    /// RMS level in dBFS of channel 0; −160 for silence or empty buffers.
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -160 }
        var meanSquare: Float = 0
        vDSP_measqv(data, 1, &meanSquare, vDSP_Length(buffer.frameLength))
        guard meanSquare > 0 else { return -160 }
        return max(-160, 10 * log10f(meanSquare))
    }
}
```
`TranslateCall/Core/Audio/SyncBox.swift` (moved from `AudioManager.swift:24-30`, now shared by `MicTap` and `SystemTap`):
```swift
/// Mutable box for state shared with an `AVAudioConverterInputBlock`.
// SAFETY: the converter invokes its input block synchronously on the calling thread, never concurrently.
nonisolated final class SyncBox<T>: @unchecked Sendable {
    nonisolated(unsafe) var value: T
    init(_ value: T) { self.value = value }
}
```

`AudioError.swift` — add a case and its description:
```swift
    case alreadyCapturing
    …
        case .alreadyCapturing:
            return "Microphone capture is already running."
```

`AudioManager.swift`:
- Protocol (lines 13-20):
```swift
@MainActor
protocol AudioCapture: AnyObject {
    /// Starts a capture session and returns its 16 kHz mono stream; `stopCapture()` finishes it.
    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer>
    func stopCapture()
}
```
- Delete `SyncBox` (moved), both `audioStream…` properties, `_continuation48`, `_continuation16`, `_converter`, `recreateStreams()`, `handleBuffer`, `downsample`, `computeRMS`, and the `recreateStreams()` call in `init`.
- Add state: `private var session: SessionAudioStream?`
- Mark the engine:
```swift
    // SAFETY: mutated only from MainActor callers; `configureEngine` is nonisolated solely so the
    // tap closure does not inherit @MainActor (AVAudioEngine calls it off the main thread).
    nonisolated(unsafe) private let engine = AVAudioEngine()
```
- Replace `startCapture`/`stopCapture`:
```swift
    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard !isCapturing else { throw AudioError.alreadyCapturing }
        guard await requestMicrophonePermission() else { throw AudioError.permissionDenied }
        guard selectedInput != nil || !inputDevices.isEmpty else { throw AudioError.noInputDevice }
        if selectedInput == nil { selectedInput = inputDevices.first }

        let session = SessionAudioStream(label: "mic")
        do {
            try configureEngine(session: session)
        } catch {
            session.finish()
            throw error
        }
        self.session = session
        isCapturing = true
        return session.stream
    }

    func stopCapture() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        session?.finish()
        session = nil
        isCapturing = false
        inputLevel = -160
    }
```
- `selectInput` keeps its current shape for now (Task 6 replaces it) but discards the result: `if wasCapturing { Task { _ = try await self.startCapture() } }`.
- Replace `configureEngine()`:
```swift
    nonisolated private func configureEngine(session: SessionAudioStream) throws {
        engine.inputNode.removeTap(onBus: 0)
        let inputNode = engine.inputNode
        let captureFormat = inputNode.outputFormat(forBus: 0)
        guard let tap = MicTap(session: session, inputFormat: captureFormat, onLevel: { [weak self] rms in
            Task { @MainActor [weak self] in self?.inputLevel = rms }
        }) else {
            throw AudioError.engineStartFailed(
                NSError(domain: "AudioManager", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not create 16 kHz converter for \(captureFormat)"])
            )
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: captureFormat) { buffer, _ in
            tap.process(buffer)
        }
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw AudioError.engineStartFailed(error)
        }
    }
```

- [ ] **Step 5: Implement the per-session stream in `SystemAudioCaptureService`**

- Protocol (lines 31-51):
```swift
protocol SystemAudioCapture: Actor {
    /// Request Screen Recording permission and return the capturable apps, sorted by name.
    func requestPermissionAndLoadApps() async throws -> [SCRunningApplication]
    /// Starts capturing `target` and returns that session's 16 kHz mono stream; `deactivate()` finishes it.
    func activate(target: CaptureTarget) async throws -> AsyncStream<AVAudioPCMBuffer>
    /// Stops capturing and finishes the session stream.
    func deactivate() async
}
```
- Stored state: delete `audioStream16kHz`, `isActive` (`nonisolated(unsafe)`), `streamContinuation` and the `init` body; add
```swift
    private var session: SessionAudioStream?
    var isActive: Bool { captureStream != nil }

    init() {}
```
- `activate`:
```swift
    func activate(target: CaptureTarget) async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard captureStream == nil else { throw SystemAudioCaptureError.alreadyActive }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw SystemAudioCaptureError.permissionDenied
        }
        guard let display = content.displays.first else { throw SystemAudioCaptureError.noDisplayAvailable }
        let bundleID: String
        switch target {
        case .app(let id): bundleID = id
        }
        guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
            throw SystemAudioCaptureError.targetNotFound(bundleID: bundleID)
        }

        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        // … SCStreamConfiguration + converter setup unchanged …

        let session = SessionAudioStream(label: "system")
        let bridge = SCStreamOutputBridge(service: self)
        outputBridge = bridge
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: nil)
            try await stream.startCapture()
        } catch {
            session.finish()
            converter = nil
            outputBridge = nil
            throw SystemAudioCaptureError.streamFailed(underlying: error)
        }
        self.session = session
        captureStream = stream
        logger.info("System audio capture activated (app: \(bundleID, privacy: .public))")
        return session.stream
    }
```
Delete `buildContentFilter` and its "all apps" branch (D-3).
- `deactivate`:
```swift
    func deactivate() async {
        guard let captureStream else { return }
        do {
            try await captureStream.stopCapture()
        } catch {
            logger.warning("SCStream stopCapture error (ignored): \(error.localizedDescription)")
        }
        session?.finish()
        session = nil
        self.captureStream = nil
        outputBridge = nil
        converter = nil
        logger.info("System audio capture deactivated")
    }
```
- `handleCapturedBuffer`: `session?.yield(downsampled)`.

- [ ] **Step 6: Wire the coordinator, setup manager and view model**

`AudioCoordinator.swift` `start` signature and incoming call:
```swift
    func start(captureTarget: CaptureTarget? = nil, blackHoleDeviceID: AudioDeviceID? = nil) async {
        …
        isOutgoingActive = true
        await startIncomingPipeline(captureTarget: captureTarget)
    }
```

`AudioCoordinator+Pipeline.swift`:
- In `startOutgoingPipeline`: `let micStream = try await audioCapture.startCapture()` and `try await vad.activate(stream: micStream)`.
- `startIncomingPipeline(captureTarget: CaptureTarget?)`: `guard let captureTarget else { logger.info("Incoming: skipped — no capture target"); return }`, then `let systemStream = try await systemCapture.activate(target: captureTarget)` and `try await vad.activate(stream: systemStream)`; rest unchanged.

`SetupManager.swift` — add below `selectCaptureApp`:
```swift
    /// Incoming capture target from the persisted selection (F8.5.1 REQ-C-22). Independent of
    /// whether the app is running now: a missing app becomes `targetNotFound` + Retry at start.
    var captureTarget: CaptureTarget? {
        let bundleID = defaults.string(forKey: Self.captureAppBundleKey) ?? ""
        return bundleID.isEmpty ? nil : .app(bundleID: bundleID)
    }
```

`AudioViewModel.startPipeline()`: `captureTarget: setupManager.captureTarget,` instead of `captureApp: setupManager.selectedCaptureApp,`.

- [ ] **Step 7: Run tests to verify they pass**

Run: `just test-only AudioCoordinatorTests SetupManagerTests SystemAudioCaptureServiceTests SessionAudioStreamTests`
Expected: PASS; `AudioCoordinatorTests` has no disabled tests left.
Then: `just build` → `** BUILD SUCCEEDED **`, and `rg -n "audioStream16kHz|audioStream48kHz" TranslateCall TranslateCallTests` → no matches.

- [ ] **Step 8: Commit**

```bash
git add -A TranslateCall TranslateCallTests
git commit -m "fix(audio): one stream per capture session, returned by start (A1, A4, T1)

startCapture()/activate(target:) now return a fresh bounded stream; stop
finishes it. Removes the unconsumed 48 kHz stream and re-enables the five
AudioCoordinator tests via CaptureTarget."
```

---

### Task 3: `CoreAudioDevices` (CoreAudio queries out of `AudioManager`)

**Files:**
- Create: `TranslateCall/Core/Audio/CoreAudioDevices.swift`
- Modify: `TranslateCall/Core/Audio/AudioManager.swift` (move `enumerateCoreAudioDevices`, `makeDevice`, `stringProperty`, `channelCount`)
- Test: `TranslateCallTests/CoreAudioDevicesTests.swift`

**Interfaces:**
- Produces:
```swift
nonisolated enum CoreAudioDevices {
    static func allDevices() -> [AudioDevice]
    static func defaultInputDeviceID() -> AudioDeviceID?
    static func setCurrentDevice(_ id: AudioDeviceID, on unit: AudioUnit) throws   // throws CoreAudioError.status(OSStatus)
    static func currentDevice(of unit: AudioUnit) -> AudioDeviceID?
}
nonisolated enum CoreAudioError: Error, Equatable { case status(OSStatus) }
```

- [ ] **Step 1: Write the failing test**

`TranslateCallTests/CoreAudioDevicesTests.swift`:
```swift
import AVFoundation
import CoreAudio
import Testing
@testable import TranslateCall

@Suite("CoreAudioDevices")
struct CoreAudioDevicesTests {

    @Test("allDevices returns devices with unique IDs and input/output flags")
    func allDevicesAreWellFormed() {
        let devices = CoreAudioDevices.allDevices()
        #expect(Set(devices.map(\.id)).count == devices.count)
        #expect(devices.allSatisfy { $0.hasInput || $0.hasOutput })
    }

    @Test("default input device, when present, is one of the input devices")
    func defaultInputIsAnInput() {
        guard let id = CoreAudioDevices.defaultInputDeviceID() else { return }  // no input hardware at all
        #expect(CoreAudioDevices.allDevices().contains { $0.id == id && $0.hasInput })
    }
}
```

`setCurrentDevice`/`currentDevice` need a live AUHAL unit (touching `AVAudioEngine.inputNode` is hardware), so they are exercised by the integration tier in Task 8, not here.

- [ ] **Step 2: Run to verify it fails**

Run: `just test-only CoreAudioDevicesTests`
Expected: build FAILS — `cannot find 'CoreAudioDevices' in scope`.

- [ ] **Step 3: Implement**

`TranslateCall/Core/Audio/CoreAudioDevices.swift`:
```swift
import AudioToolbox
import CoreAudio
import Foundation

nonisolated enum CoreAudioError: Error, Equatable {
    case status(OSStatus)
}

/// Thin CoreAudio HAL queries shared by AudioManager and tests (F8.5.1 §3.4).
nonisolated enum CoreAudioDevices {

    static func allDevices() -> [AudioDevice] {
        // body of AudioManager.enumerateCoreAudioDevices(), using makeDevice below
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Binds an AUHAL unit (e.g. `AVAudioEngine.inputNode.audioUnit`) to a device. Engine must be stopped.
    static func setCurrentDevice(_ id: AudioDeviceID, on unit: AudioUnit) throws {
        var deviceID = id
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw CoreAudioError.status(status) }
    }

    static func currentDevice(of unit: AudioUnit) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, &size
        )
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    // makeDevice(id:), stringProperty(_:selector:scope:), channelCount(_:scope:) moved verbatim
    // from AudioManager.swift as `private static func`.
}
```
Move the four helpers from `AudioManager.swift` verbatim (as `private static`), and change `AudioManager.refreshDevices()` to `let all = CoreAudioDevices.allDevices()`.

- [ ] **Step 4: Run to verify it passes**

Run: `just test-only CoreAudioDevicesTests AudioManagerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Core/Audio/CoreAudioDevices.swift TranslateCall/Core/Audio/AudioManager.swift TranslateCallTests/CoreAudioDevicesTests.swift
git commit -m "refactor(audio): extract CoreAudio device queries into CoreAudioDevices"
```

---

### Task 4: `SystemTap`, owned buffers, stream delegate and events (A2, A1b service side)

**Files:**
- Create: `TranslateCall/Core/Audio/SystemTap.swift`
- Modify: `TranslateCall/Core/Audio/SystemAudioCaptureService.swift` (protocol, state, `activate`, `deactivate`, remove `handleCapturedBuffer`/`downsample`/`extractPCMBuffer`, bridge 256-278)
- Modify: `TranslateCallTests/Mocks/MockSystemAudioCapture.swift`
- Test: `TranslateCallTests/SystemAudioCaptureServiceTests.swift`

**Interfaces:**
- Consumes: `SessionAudioStream`, `SystemCaptureEvent`, `IncomingStopReason` (Task 1); `activate(target:)` (Task 2).
- Produces:
  - `SystemAudioCapture` protocol gains `nonisolated var events: AsyncStream<SystemCaptureEvent> { get }`
  - `nonisolated final class SystemTap: @unchecked Sendable { init(session: SessionAudioStream) throws; func process(_ sampleBuffer: CMSampleBuffer); static func extractOwnedPCMBuffer(from: CMSampleBuffer) -> AVAudioPCMBuffer? }`
  - `SystemAudioCaptureService.stopReason(for error: Error) -> IncomingStopReason` (static, nonisolated)
  - `@discardableResult func handleStreamStopped(_ reason: IncomingStopReason, generation: UInt64) -> Bool` (actor-isolated)
  - `MockSystemAudioCapture.emit(_ event: SystemCaptureEvent)`

- [ ] **Step 1: Write the failing tests**

In `TranslateCallTests/SystemAudioCaptureServiceTests.swift`, delete `extractPCMBufferFromEmptyBufferReturnsNil` and `downsampleProduces16kHzOutput`, and add:
```swift
    // MARK: - SystemTap (A2: owned memory)

    @Test("extracted buffer owns its samples: wiping the sample buffer does not change them")
    func extractedBufferOwnsMemory() throws {
        let sine = makeSine48k(frames: 480)
        let sampleBuffer = try makeSampleBuffer(copying: sine)
        let extracted = try #require(SystemTap.extractOwnedPCMBuffer(from: sampleBuffer))

        // Overwrite the CMSampleBuffer's backing memory with zeros.
        let block = try #require(CMSampleBufferGetDataBuffer(sampleBuffer))
        #expect(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                           dataLength: CMBlockBufferGetDataLength(block)) == noErr)

        #expect(extracted.frameLength == 480)
        let got = Array(UnsafeBufferPointer(start: extracted.floatChannelData![0], count: 480))
        let want = Array(UnsafeBufferPointer(start: sine.floatChannelData![0], count: 480))
        #expect(got == want)
    }

    @Test("extract returns nil when the sample buffer has no data")
    func extractNilWithoutData() {
        #expect(SystemTap.extractOwnedPCMBuffer(from: makeSilentAudioSampleBuffer()) == nil)
    }

    @Test("extract rejects non-Float32 PCM")
    func rejectsNonFloatFormat() throws {
        let int16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: int16, frameCapacity: 480)!
        buffer.frameLength = 480
        let sampleBuffer = try makeSampleBuffer(copying: buffer)
        #expect(SystemTap.extractOwnedPCMBuffer(from: sampleBuffer) == nil)
    }

    @Test("process yields a 16 kHz mono buffer into the session")
    func processYields16k() async throws {
        let session = SessionAudioStream(label: "test")
        let tap = try SystemTap(session: session)
        tap.process(try makeSampleBuffer(copying: makeSine48k(frames: 4800)))
        session.finish()
        var buffers: [AVAudioPCMBuffer] = []
        for await buffer in session.stream { buffers.append(buffer) }
        let first = try #require(buffers.first)
        #expect(first.format.sampleRate == 16_000)
        #expect(first.format.channelCount == 1)
        #expect(first.frameLength > 0)
    }

    // MARK: - Stream stop handling (A1b)

    @Test("stopReason maps userDeclined to permissionDenied, anything else to streamError")
    func stopReasonMapping() {
        #expect(SystemAudioCaptureService.stopReason(for: SCStreamError(.userDeclined)) == .permissionDenied)
        let other = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "gone"])
        #expect(SystemAudioCaptureService.stopReason(for: other) == .streamError("gone"))
    }

    @Test("a stop callback while inactive or from an old generation is ignored")
    func staleStopIgnored() async {
        let service = SystemAudioCaptureService()
        #expect(await service.handleStreamStopped(.streamError("late"), generation: 0) == false)
        #expect(await service.handleStreamStopped(.streamError("late"), generation: 42) == false)
    }
```
Add helpers at the bottom of the file:
```swift
private func makeSine48k(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let buffer = make48kHzBuffer(frameCount: frames)
    let data = buffer.floatChannelData![0]
    for i in 0..<Int(frames) { data[i] = 0.5 * sinf(2 * .pi * 440 * Float(i) / 48_000) }
    return buffer
}

/// CMSampleBuffer whose block buffer holds a *copy* of `pcm` (CMSampleBufferSetDataBufferFromAudioBufferList copies).
private func makeSampleBuffer(copying pcm: AVAudioPCMBuffer) throws -> CMSampleBuffer {
    var formatDescription: CMAudioFormatDescription?
    #expect(CMAudioFormatDescriptionCreate(allocator: nil, asbd: pcm.format.streamDescription, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &formatDescription) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
                                    presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    #expect(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                 refcon: nil, formatDescription: formatDescription,
                                 sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1,
                                 sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                 sampleBufferOut: &sampleBuffer) == noErr)
    let result = try #require(sampleBuffer)
    #expect(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: nil,
                                                           blockBufferMemoryAllocator: nil, flags: 0,
                                                           bufferList: pcm.audioBufferList) == noErr)
    return result
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `just test-only SystemAudioCaptureServiceTests`
Expected: build FAILS — `cannot find 'SystemTap' in scope`, `type 'SystemAudioCaptureService' has no member 'stopReason'`.

- [ ] **Step 3: Implement `SystemTap`**

`TranslateCall/Core/Audio/SystemTap.swift`:
```swift
import AVFoundation
import CoreMedia
import os

nonisolated private let logger = Logger(subsystem: "TranslateCall", category: "SystemTap")

/// Per-activation SCStream audio handler: copies samples out of the CMSampleBuffer (A2),
/// downsamples 48 kHz → 16 kHz mono and yields into the session stream.
///
// SAFETY: used only on SystemAudioCaptureService's serial `sampleQueue`; one SystemTap per
// activation, so `converter` is never touched concurrently.
nonisolated final class SystemTap: @unchecked Sendable {
    private let session: SessionAudioStream
    private let converter: AVAudioConverter

    init(session: SessionAudioStream) throws {
        guard let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let output = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: input, to: output)
        else {
            throw SystemAudioCaptureError.streamFailed(underlying: NSError(
                domain: "TranslateCall", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"]))
        }
        self.session = session
        self.converter = converter
    }

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.extractOwnedPCMBuffer(from: sampleBuffer),
              let converted = downsample(pcm) else { return }
        session.yield(converted)
    }

    /// Copies the sample buffer's Float32 PCM into a newly allocated buffer (REQ-C-40).
    /// Returns nil for empty, not-ready or non-Float32 buffers.
    static func extractOwnedPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32,
              let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                         channels: asbd.mChannelsPerFrame)
        else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let destination = pcm.floatChannelData
        else { return nil }
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 && asbd.mChannelsPerFrame > 1
        guard !interleaved else {
            logger.warning("Interleaved multi-channel SCStream audio is not supported — buffer dropped")
            return nil
        }
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                for (channel, buffer) in list.enumerated() where channel < Int(format.channelCount) {
                    guard let source = buffer.mData else { continue }
                    let bytes = min(Int(buffer.mDataByteSize), Int(frames) * MemoryLayout<Float>.size)
                    memcpy(destination[channel], source, bytes)
                }
            }
        } catch {
            return nil
        }
        pcm.frameLength = frames
        return pcm
    }

    private func downsample(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        let provided = SyncBox(false)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if provided.value { outStatus.pointee = .noDataNow; return nil }
            provided.value = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error else {
            logger.warning("AVAudioConverter error: \(conversionError?.localizedDescription ?? "unknown")")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }
}
```

- [ ] **Step 4: Implement events, delegate and generation in the service**

In `SystemAudioCaptureService.swift`:
- Protocol: add `nonisolated var events: AsyncStream<SystemCaptureEvent> { get }` with doc “Lives as long as the service. Subscribe once and never cancel the iterating task — cancelling terminates the stream.”
- State and init:
```swift
    nonisolated let events: AsyncStream<SystemCaptureEvent>
    private let eventsContinuation: AsyncStream<SystemCaptureEvent>.Continuation
    private let sampleQueue = DispatchQueue(label: "TranslateCall.SystemAudioCapture.samples")
    private var generation: UInt64 = 0
    private var session: SessionAudioStream?
    private var captureStream: SCStream?
    private var bridge: SCStreamBridge?
    var isActive: Bool { captureStream != nil }

    init() {
        (events, eventsContinuation) = AsyncStream.makeStream(
            of: SystemCaptureEvent.self, bufferingPolicy: .bufferingNewest(8)
        )
    }
```
  Delete `outputBridge`, `converter`, `handleCapturedBuffer`, `downsample`, `extractPCMBuffer`.
- In `activate`, after resolving `app` and building `filter`/`config` (drop the converter block; `SystemTap` owns it):
```swift
        generation &+= 1
        let session = SessionAudioStream(label: "system")
        let tap = try SystemTap(session: session)
        let bridge = SCStreamBridge(service: self, generation: generation, tap: tap)
        let stream = SCStream(filter: filter, configuration: config, delegate: bridge)
        do {
            try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
        } catch {
            session.finish()
            throw SystemAudioCaptureError.streamFailed(underlying: error)
        }
        self.session = session
        self.bridge = bridge
        captureStream = stream
        return session.stream
```
- `deactivate` also clears `bridge` (no event emitted).
- Add:
```swift
    /// Maps an SCStream stop error to a user-facing reason.
    nonisolated static func stopReason(for error: Error) -> IncomingStopReason {
        if let streamError = error as? SCStreamError, streamError.code == .userDeclined {
            return .permissionDenied
        }
        return .streamError(error.localizedDescription)
    }

    /// Called from the SCStream delegate. Ignores callbacks from a previous activation or while inactive.
    @discardableResult
    func handleStreamStopped(_ reason: IncomingStopReason, generation callbackGeneration: UInt64) -> Bool {
        guard callbackGeneration == generation, captureStream != nil else { return false }
        logger.error("System audio capture stopped: \(reason.message, privacy: .public)")
        session?.finish()
        session = nil
        captureStream = nil
        bridge = nil
        eventsContinuation.yield(.stopped(reason))
        return true
    }
```
- Replace `SCStreamOutputBridge` with:
```swift
/// Receives SCStream sample buffers (on `sampleQueue`) and stop errors, forwarding to the tap / actor.
private final class SCStreamBridge: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // SAFETY: assigned once in init and never mutated; `weak` requires `var`.
    nonisolated(unsafe) private weak var service: SystemAudioCaptureService?
    private let generation: UInt64
    private let tap: SystemTap

    nonisolated init(service: SystemAudioCaptureService, generation: UInt64, tap: SystemTap) {
        self.service = service
        self.generation = generation
        self.tap = tap
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        tap.process(sampleBuffer)   // synchronous on sampleQueue: the CMSampleBuffer never escapes
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let service else { return }
        let reason = SystemAudioCaptureService.stopReason(for: error)
        let generation = generation
        Task { await service.handleStreamStopped(reason, generation: generation) }
    }
}
```

In `MockSystemAudioCapture`, add:
```swift
    nonisolated let events: AsyncStream<SystemCaptureEvent>
    private let eventsContinuation: AsyncStream<SystemCaptureEvent>.Continuation

    init() {
        (events, eventsContinuation) = AsyncStream.makeStream(of: SystemCaptureEvent.self, bufferingPolicy: .bufferingNewest(8))
    }

    /// Simulates an out-of-band event (e.g. the SCStream died). Finishes the stream for `.stopped`.
    func emit(_ event: SystemCaptureEvent) {
        if case .stopped = event { continuation?.finish(); continuation = nil }
        eventsContinuation.yield(event)
    }
```

- [ ] **Step 5: Run to verify they pass**

Run: `just test-only SystemAudioCaptureServiceTests AudioCoordinatorTests`
Expected: PASS. Then `rg -n "bufferListNoCopy" TranslateCall` → no matches.

- [ ] **Step 6: Commit**

```bash
git add -A TranslateCall/Core/Audio TranslateCallTests
git commit -m "fix(audio): copy SCStream samples and report stream stops (A2, A1b)

SystemTap copies CMSampleBuffer PCM into owned buffers on a serial queue
(no per-buffer Task); the SCStream delegate emits .stopped on a long-lived
events stream, ignoring callbacks from previous activations."
```

---

### Task 5: Coordinator incoming status, stop events and Retry (A1b, REQ-C-30…35)

**Files:**
- Modify: `TranslateCall/Core/Audio/AudioCoordinator.swift` (state, `start`, `stop`, add `retryIncoming`)
- Modify: `TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift` (replace `startIncomingPipeline` with `activateIncoming`; add event handling and teardown)
- Modify: `TranslateCallTests/Mocks/MockSystemAudioCapture.swift` (activation gate)
- Test: `TranslateCallTests/AudioCoordinatorTests.swift`

**Interfaces:**
- Consumes: `IncomingStatus`, `IncomingStopReason`, `SystemCaptureEvent` (Task 1); `events`, `emit` (Task 4); `activate(target:)` (Task 2).
- Produces:
  - `AudioCoordinator.incomingStatus: IncomingStatus` (`@Published private(set)`), `isIncomingActive` becomes `@Published private(set)` derived from it
  - `AudioCoordinator.retryIncoming()`
  - `MockSystemAudioCapture.holdNextActivation()`, `.releaseActivation()`, `.isWaitingAtGate: Bool`

- [ ] **Step 1: Add the activation gate to the mock**

```swift
    private var holdActivation = false
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var isWaitingAtGate = false

    /// The next `activate` suspends until `releaseActivation()`.
    func holdNextActivation() { holdActivation = true }
    func releaseActivation() { gate?.resume(); gate = nil }
```
and at the top of `activate(target:)`, before `throwOnActivate`:
```swift
        if holdActivation {
            holdActivation = false
            isWaitingAtGate = true
            await withCheckedContinuation { gate = $0 }
            isWaitingAtGate = false
        }
```
Add `func setThrowOnActivate(_ error: Error?)` stays in the test file extension (already present).

- [ ] **Step 2: Write the failing tests**

Append to `AudioCoordinatorTests`:
```swift
    @Test("no capture target → incoming .disabled and system capture untouched")
    func noTargetDisablesIncoming() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()
        #expect(coordinator.incomingStatus == .disabled)
        #expect(!(await mocks.mockSystemCapture.activateCalled))
    }

    @Test("target app not running → .stopped(.targetNotFound), outgoing keeps running, no alert")
    func targetNotFoundStops() async {
        let mocks = CoordinatorMocks()
        await mocks.mockSystemCapture.setThrowOnActivate(SystemAudioCaptureError.targetNotFound(bundleID: "com.test.call"))
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        #expect(coordinator.incomingStatus == .stopped(.targetNotFound(bundleID: "com.test.call")))
        #expect(coordinator.isOutgoingActive)
        #expect(!coordinator.isIncomingActive)
        #expect(coordinator.errorAlert == nil)
    }

    @Test("stream stops mid-session → incoming torn down, .stopped, outgoing alive, speaking released")
    func streamStopTearsDownIncoming() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        coordinator.isIncomingSpeaking = true

        await mocks.mockSystemCapture.emit(.stopped(.streamError("boom")))

        #expect(await waitUntil { coordinator.incomingStatus == .stopped(.streamError("boom")) })
        #expect(await mocks.mockIncomingVAD.deactivateCalled)
        #expect(await mocks.mockIncomingSTT.deactivateCalled)
        #expect(await mocks.mockIncomingTTS.deactivateCalled)
        #expect(!coordinator.isIncomingSpeaking)
        #expect(coordinator.isOutgoingActive)
    }

    @Test("Retry after a stop reactivates incoming with a fresh stream")
    func retryReactivates() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        await mocks.mockSystemCapture.emit(.stopped(.streamError("boom")))
        #expect(await waitUntil { coordinator.incomingStatus == .stopped(.streamError("boom")) })

        coordinator.retryIncoming()

        #expect(await waitUntil { coordinator.incomingStatus == .active })
        await mocks.mockSystemCapture.injectBuffer(makePCMBuffer())
        #expect(await waitUntil { await mocks.mockIncomingVAD.receivedBufferCount == 1 })
        #expect(await mocks.mockSystemCapture.activatedTargets.count == 2)
    }

    @Test("Retry twice in a row activates once")
    func doubleRetryActivatesOnce() async {
        let mocks = CoordinatorMocks()
        await mocks.mockSystemCapture.setThrowOnActivate(SystemAudioCaptureError.targetNotFound(bundleID: "com.test.call"))
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        await mocks.mockSystemCapture.setThrowOnActivate(nil)

        coordinator.retryIncoming()
        coordinator.retryIncoming()

        #expect(await waitUntil { coordinator.incomingStatus == .active })
        #expect(await mocks.mockSystemCapture.activatedTargets.count == 1)
    }

    @Test("Retry is a no-op unless incoming is stopped")
    func retryOnlyWhenStopped() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        coordinator.retryIncoming()
        #expect(coordinator.incomingStatus == .active)
        #expect(await mocks.mockSystemCapture.activatedTargets.count == 1)
    }

    @Test("stop() during an in-flight activation leaves nothing alive and ends .idle")
    func stopDuringActivationTearsDown() async {
        let mocks = CoordinatorMocks()
        await mocks.mockSystemCapture.holdNextActivation()
        let coordinator = makeCoordinator(mocks)

        let starting = Task { await coordinator.start(captureTarget: callTarget) }
        #expect(await waitUntil { await mocks.mockSystemCapture.isWaitingAtGate })
        let stopping = Task { await coordinator.stop() }
        await mocks.mockSystemCapture.releaseActivation()
        await starting.value
        await stopping.value

        #expect(coordinator.incomingStatus == .idle)
        #expect(await mocks.mockIncomingVAD.activateCount == 0)
        #expect(await mocks.mockSystemCapture.deactivateCalled)
        #expect(!coordinator.isOutgoingActive)
    }

    @Test("stream stop while incoming is still starting ends .stopped, not .active")
    func stopEventDuringStartingEndsStopped() async {
        let mocks = CoordinatorMocks()
        await mocks.mockSystemCapture.holdNextActivation()
        let coordinator = makeCoordinator(mocks)

        let starting = Task { await coordinator.start(captureTarget: callTarget) }
        #expect(await waitUntil { await mocks.mockSystemCapture.isWaitingAtGate })
        #expect(await waitUntil { coordinator.incomingStatus == .starting })
        await mocks.mockSystemCapture.emit(.stopped(.streamError("died")))
        #expect(await waitUntil { coordinator.pendingStopReasonForTesting != nil })
        await mocks.mockSystemCapture.releaseActivation()
        await starting.value

        #expect(coordinator.incomingStatus == .stopped(.streamError("died")))
        #expect(!coordinator.isIncomingActive)
    }

    @Test("stop() resets incoming status to .idle")
    func stopResetsStatus() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        await coordinator.stop()
        #expect(coordinator.incomingStatus == .idle)
        #expect(!coordinator.isIncomingActive)
    }
```
Also add to the existing `startSkipsIncomingOnPermissionDenied`: `#expect(coordinator.incomingStatus == .stopped(.permissionDenied))` (its `errorAlert != nil` expectation stays — permission denial keeps the "Open Settings" alert).

- [ ] **Step 3: Run to verify they fail**

Run: `just test-only AudioCoordinatorTests`
Expected: build FAILS — `value of type 'AudioCoordinator' has no member 'incomingStatus'` / `retryIncoming` / `pendingStopReasonForTesting`.

- [ ] **Step 4: Implement**

`AudioCoordinator.swift` — replace `@Published var isIncomingActive: Bool = false` with:
```swift
    @Published private(set) var incomingStatus: IncomingStatus = .idle {
        didSet { isIncomingActive = (incomingStatus == .active) }
    }
    /// Derived from `incomingStatus`; kept as its own publisher for existing bindings.
    @Published private(set) var isIncomingActive: Bool = false
```
and add (internal so the `+Pipeline` extension can use them):
```swift
    /// Bumped by start() and stop(); an activation that sees a different value was superseded.
    var sessionGeneration: UInt64 = 0
    var captureTarget: CaptureTarget?
    /// Subscribed once to `systemCapture.events` and never cancelled: cancelling the iterating
    /// task would terminate the service's long-lived stream (the A1 bug class).
    var incomingEventsTask: Task<Void, Never>?
    var incomingActivationTask: Task<Void, Never>?
    /// A `.stopped` event that arrived while incoming was `.starting`.
    var pendingStopReason: IncomingStopReason?
    var pendingStopReasonForTesting: IncomingStopReason? { pendingStopReason }
```
`start`:
```swift
    func start(captureTarget: CaptureTarget? = nil, blackHoleDeviceID: AudioDeviceID? = nil) async {
        guard !isOutgoingActive else { return }
        sessionGeneration &+= 1
        self.captureTarget = captureTarget
        setupHalfDuplex()
        isStarting = true
        defer { isStarting = false }

        do {
            try await startOutgoingPipeline(blackHoleDeviceID: blackHoleDeviceID)
        } catch {
            errorAlert = makeAlertItem(for: error)
            return
        }

        isOutgoingActive = true
        subscribeToIncomingEvents()
        let activation = Task { await self.activateIncoming() }
        incomingActivationTask = activation
        await activation.value
    }
```
`stop` — at the very top:
```swift
        sessionGeneration &+= 1
        let pendingActivation = incomingActivationTask
        incomingActivationTask = nil
        await pendingActivation?.value   // a superseded activation tears itself down
```
replace the incoming block with `await systemCapture.deactivate()` followed by `await teardownIncomingServices()`, delete `isIncomingActive = false`, and add `incomingStatus = .idle` and `pendingStopReason = nil` next to the other resets.
Add:
```swift
    /// Re-runs incoming activation after a stop (REQ-C-34). No-op unless `.stopped`.
    func retryIncoming() {
        guard case .stopped = incomingStatus, isOutgoingActive else { return }
        incomingStatus = .starting
        incomingActivationTask = Task { await self.activateIncoming() }
    }
```

`AudioCoordinator+Pipeline.swift` — delete `startIncomingPipeline` and add:
```swift
    private struct SupersededActivation: Error {}

    private func ensureCurrent(_ generation: UInt64) throws {
        guard generation == sessionGeneration else { throw SupersededActivation() }
    }

    /// Starts (or restarts) the incoming pipeline. Never throws: the outcome is `incomingStatus`.
    func activateIncoming() async {
        guard let captureTarget else {
            incomingStatus = .disabled
            logger.info("Incoming: disabled — no capture target")
            return
        }
        incomingStatus = .starting
        pendingStopReason = nil
        let generation = sessionGeneration
        do {
            let systemStream = try await systemCapture.activate(target: captureTarget)
            try ensureCurrent(generation)

            let vad = incomingVADFactory()
            incomingVAD = vad
            try await vad.activate(stream: systemStream)
            try ensureCurrent(generation)

            let targetLocale = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
            let stt = incomingSTTFactory(targetLocale)
            incomingSTT = stt
            try await stt.activate(stream: vad.speechSegments)
            try ensureCurrent(generation)
            observeIncomingTranscriptions(stt)

            let sourceLocaleForTTS = Locale(identifier: languagePairManager.sourceLanguage.minimalIdentifier)
            let tts = try incomingTTSFactory(sourceLocaleForTTS, nil)
            incomingTTS = tts
            observeTTSState(tts, onSpeakingChange: { [weak self] speaking in
                self?.isIncomingSpeaking = speaking
            }, into: &incomingTasks)

            if let reason = pendingStopReason {
                pendingStopReason = nil
                await teardownIncomingServices()
                await systemCapture.deactivate()
                incomingStatus = .stopped(reason)
                return
            }
            incomingStatus = .active
            logger.info("Incoming: active")
        } catch is SupersededActivation {
            await teardownIncomingServices()
            await systemCapture.deactivate()
            logger.info("Incoming: activation superseded by stop()")
        } catch {
            await teardownIncomingServices()
            await systemCapture.deactivate()
            if case SystemAudioCaptureError.permissionDenied = error {
                errorAlert = makeAlertItem(for: error)
            }
            incomingStatus = .stopped(IncomingStopReason(error: error))
            logger.warning("Incoming: stopped — \(error.localizedDescription)")
        }
    }

    func subscribeToIncomingEvents() {
        guard incomingEventsTask == nil else { return }
        let events = systemCapture.events
        incomingEventsTask = Task { [weak self] in
            for await event in events {
                await self?.handleIncomingEvent(event)
            }
        }
    }

    func handleIncomingEvent(_ event: SystemCaptureEvent) async {
        guard case .stopped(let reason) = event else { return }
        switch incomingStatus {
        case .starting:
            pendingStopReason = reason
        case .active:
            await teardownIncomingServices()
            isIncomingSpeaking = false
            incomingStatus = .stopped(reason)
            logger.warning("Incoming: stopped mid-session — \(reason.message)")
        default:
            break
        }
    }

    /// Deactivates and releases incoming VAD/STT/TTS and their observation tasks.
    func teardownIncomingServices() async {
        incomingTasks.forEach { $0.cancel() }
        incomingTasks.removeAll()
        await incomingVAD?.deactivate()
        await incomingSTT?.deactivate()
        await incomingTTS?.deactivate()
        incomingVAD = nil
        incomingSTT = nil
        incomingTTS = nil
    }
```
Note for the stop-during-activation test: `stop()` awaits `pendingActivation`, which is blocked inside `systemCapture.activate` until the test releases the gate — the test launches `stop()` in its own Task for that reason.

- [ ] **Step 5: Run to verify they pass**

Run: `just test-only AudioCoordinatorTests HalfDuplexManagerTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add TranslateCall/Core/Audio/AudioCoordinator.swift TranslateCall/Core/Audio/AudioCoordinator+Pipeline.swift \
        TranslateCallTests/Mocks/MockSystemAudioCapture.swift TranslateCallTests/AudioCoordinatorTests.swift
git commit -m "feat(audio): incoming status with stop events and Retry (A1b)

Incoming failures degrade to .stopped(reason) while outgoing keeps running;
retryIncoming() reactivates with a fresh stream; stop() waits for and
supersedes an in-flight activation."
```

---

### Task 6: Mic device selection, hot swap and fallback (A5, A5b, REQ-C-10…13)

**Files:**
- Modify: `TranslateCall/Core/Audio/AudioManager.swift`
- Modify: `TranslateCall/Core/Audio/AudioError.swift`
- Modify: `TranslateCall/Features/Main/AudioViewModel.swift` (`selectInput` catch, `bindAudioManager`)
- Test: `TranslateCallTests/AudioManagerTests.swift`

**Interfaces:**
- Consumes: `CoreAudioDevices` (Task 3), `MicTap`, `SessionAudioStream` (Tasks 1-2).
- Produces:
  - `static func AudioManager.chooseInput(selectedUID: String?, available: [AudioDevice], defaultID: AudioDeviceID?) -> AudioDevice?` (nonisolated)
  - `AudioManager.deviceNotice: String?` (`@Published private(set)`)
  - `AudioManager.activeInputDeviceID: AudioDeviceID?` (reads the input unit's `CurrentDevice`; used by integration tests)
  - `AudioError.deviceSwitchFailed(String, Error)`
  - `AudioManager.init(defaults:configure:)` with an injectable configure hook (tests only)

- [ ] **Step 1: Write the failing tests**

In `TranslateCallTests/AudioManagerTests.swift` add a suite:
```swift
@Suite("AudioManager input choice") @MainActor
struct AudioManagerInputChoiceTests {
    private let usb = AudioDevice(id: 10, name: "USB Mic", uid: "usb", hasInput: true, hasOutput: false)
    private let builtIn = AudioDevice(id: 20, name: "MacBook Mic", uid: "builtin", hasInput: true, hasOutput: false)
    private let blackHole = AudioDevice(id: 30, name: "BlackHole 2ch", uid: "bh", hasInput: true, hasOutput: true)

    @Test("selected device wins when present")
    func selectedWins() {
        #expect(AudioManager.chooseInput(selectedUID: "usb", available: [builtIn, usb], defaultID: 20) == usb)
    }

    @Test("missing selected device falls back to the system default")
    func fallsBackToDefault() {
        #expect(AudioManager.chooseInput(selectedUID: "usb", available: [blackHole, builtIn], defaultID: 20) == builtIn)
    }

    @Test("no default falls back to the first input; nothing available → nil")
    func fallsBackToFirst() {
        #expect(AudioManager.chooseInput(selectedUID: nil, available: [blackHole, builtIn], defaultID: nil) == blackHole)
        #expect(AudioManager.chooseInput(selectedUID: "usb", available: [], defaultID: 20) == nil)
    }
}

@Suite("AudioManager device switching") @MainActor
struct AudioManagerSwitchTests {
    /// Records configure calls and fails for device IDs in `failing`.
    final class ConfigureSpy {
        var calls: [AudioDeviceID] = []
        var failing: Set<AudioDeviceID> = []
        func configure(_ id: AudioDeviceID, _ session: SessionAudioStream) throws {
            calls.append(id)
            if failing.contains(id) { throw CoreAudioError.status(-1) }
        }
    }

    private func makeManager(_ spy: ConfigureSpy) -> AudioManager {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return AudioManager(defaults: defaults, configure: { try spy.configure($0, $1) })
    }

    private let micA = AudioDevice(id: 101, name: "Mic A", uid: "a", hasInput: true, hasOutput: false)
    private let micB = AudioDevice(id: 102, name: "Mic B", uid: "b", hasInput: true, hasOutput: false)

    @Test("switch failure keeps the previous device and the session stream alive")
    func switchFailureKeepsPreviousDevice() async throws {
        let spy = ConfigureSpy()
        let manager = makeManager(spy)
        manager.injectInputDevicesForTesting([micA, micB])
        try manager.selectInput(micA)
        let stream = try await manager.startCaptureSkippingPermissionForTesting()
        spy.failing = [micB.id]

        #expect(throws: AudioError.self) { try manager.selectInput(micB) }

        #expect(manager.selectedInput == micA)
        #expect(manager.isCapturing)
        #expect(spy.calls == [micA.id, micB.id, micA.id])
        manager.stopCapture()
        for await _ in stream {}   // returns only because stopCapture finished the still-open stream
    }

    @Test("a configuration change for the active, still-present device is ignored")
    func configChangeForActiveDeviceIsIgnored() async throws {
        let spy = ConfigureSpy()
        let manager = makeManager(spy)
        manager.injectInputDevicesForTesting([micA, micB])
        try manager.selectInput(micA)
        _ = try await manager.startCaptureSkippingPermissionForTesting()
        spy.calls.removeAll()

        manager.handleConfigurationChange(engineRunning: true)

        #expect(spy.calls.isEmpty)
        #expect(manager.deviceNotice == nil)
        manager.stopCapture()
    }

    @Test("the active device disappearing falls back and publishes a notice")
    func activeDeviceGoneFallsBack() async throws {
        let spy = ConfigureSpy()
        let manager = makeManager(spy)
        manager.injectInputDevicesForTesting([micA, micB])
        try manager.selectInput(micA)
        _ = try await manager.startCaptureSkippingPermissionForTesting()

        manager.injectInputDevicesForTesting([micB])       // A unplugged
        manager.handleConfigurationChange(engineRunning: false)

        #expect(spy.calls.last == micB.id)
        #expect(manager.selectedInput == micB)
        #expect(manager.deviceNotice?.contains("Mic A") == true)
        manager.stopCapture()
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `just test-only AudioManagerInputChoiceTests AudioManagerSwitchTests`
Expected: build FAILS — no `chooseInput`, no `init(defaults:configure:)`, no `injectInputDevicesForTesting`, no `handleConfigurationChange`.

- [ ] **Step 3: Implement**

`AudioError.swift`:
```swift
    case deviceSwitchFailed(String, Error)
    …
        case .deviceSwitchFailed(let name, let error):
            return "Could not use microphone '\(name)': \(error.localizedDescription)"
```

`AudioManager.swift`:
- State:
```swift
    @Published private(set) var deviceNotice: String?
    private var activeDevice: AudioDevice?
    private var configChangeObserver: NSObjectProtocol?
    /// Engine (re)configuration; injectable so tests can exercise switching without hardware.
    private let configure: (AudioDeviceID, SessionAudioStream) throws -> Void
    /// When true, refreshDevices() keeps the injected list (tests only).
    private var devicesInjected = false
```
- Init:
```swift
    init(defaults: UserDefaults = .standard,
         configure: ((AudioDeviceID, SessionAudioStream) throws -> Void)? = nil) {
        self.defaults = defaults
        self.configure = configure ?? { _, _ in }   // replaced below; Swift needs all stored props first
        …existing body…
        if configure == nil {
            self.configure = { [unowned self] id, session in try self.configureEngine(deviceID: id, session: session) }
        }
    }
```
(`configure` must be `private var` for this two-phase assignment.)
- Device choice:
```swift
    nonisolated static func chooseInput(selectedUID: String?, available: [AudioDevice],
                                        defaultID: AudioDeviceID?) -> AudioDevice? {
        if let selectedUID, let selected = available.first(where: { $0.uid == selectedUID }) { return selected }
        if let defaultID, let fallback = available.first(where: { $0.id == defaultID }) { return fallback }
        return available.first
    }

    var activeInputDeviceID: AudioDeviceID? {
        engine.inputNode.audioUnit.flatMap(CoreAudioDevices.currentDevice(of:))
    }
```
- `startCapture()` (permission check stays first; then):
```swift
        guard let device = Self.chooseInput(selectedUID: selectedInput?.uid, available: inputDevices,
                                            defaultID: CoreAudioDevices.defaultInputDeviceID())
        else { throw AudioError.noInputDevice }
        return try beginSession(on: device)
```
with
```swift
    private func beginSession(on device: AudioDevice) throws -> AsyncStream<AVAudioPCMBuffer> {
        let session = SessionAudioStream(label: "mic")
        do {
            try configure(device.id, session)
        } catch {
            session.finish()
            throw AudioError.engineStartFailed(error)
        }
        self.session = session
        activeDevice = device
        if selectedInput == nil { selectedInput = device }
        isCapturing = true
        observeConfigurationChanges()
        return session.stream
    }

    /// Test-only: same as startCapture() without the TCC microphone prompt.
    func startCaptureSkippingPermissionForTesting() async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard !isCapturing else { throw AudioError.alreadyCapturing }
        guard let device = Self.chooseInput(selectedUID: selectedInput?.uid, available: inputDevices, defaultID: nil)
        else { throw AudioError.noInputDevice }
        return try beginSession(on: device)
    }

    func injectInputDevicesForTesting(_ devices: [AudioDevice]) {
        devicesInjected = true
        inputDevices = devices
    }
```
and in `refreshDevices()` add `guard !devicesInjected else { return }` at the top.
- `stopCapture()` also sets `activeDevice = nil`.
- `selectInput`:
```swift
    func selectInput(_ device: AudioDevice) throws {
        guard inputDevices.contains(device) else { throw AudioError.deviceUnavailable(device.name) }
        if isCapturing, let session, device != activeDevice {
            try switchCapture(to: device, session: session)
        }
        selectedInput = device
        defaults.set(device.uid, forKey: Self.inputDeviceUIDKey)
    }

    /// Hot swap (REQ-C-11/12): same session stream, engine reconfigured on the new device.
    private func switchCapture(to device: AudioDevice, session: SessionAudioStream) throws {
        let previous = activeDevice
        engine.stop()
        do {
            try configure(device.id, session)
            activeDevice = device
        } catch {
            if let previous {
                engine.stop()
                do {
                    try configure(previous.id, session)
                } catch {
                    stopCapture()
                    deviceNotice = "Microphone capture stopped: \(error.localizedDescription)"
                }
            }
            throw AudioError.deviceSwitchFailed(device.name, error)
        }
    }
```
- Configuration change:
```swift
    private func observeConfigurationChanges() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange(engineRunning: self?.engine.isRunning ?? false) }
        }
    }

    /// REQ-C-13: keep the session alive on the selected device if present, else the default.
    func handleConfigurationChange(engineRunning: Bool) {
        guard isCapturing, let session else { return }
        refreshDevices()
        guard let target = Self.chooseInput(selectedUID: selectedInput?.uid, available: inputDevices,
                                            defaultID: CoreAudioDevices.defaultInputDeviceID())
        else {
            stopCapture()
            deviceNotice = "No microphone available — capture stopped."
            return
        }
        // Our own reconfiguration also posts this notification: nothing to do if unchanged.
        if engineRunning, target.id == activeDevice?.id { return }
        let previous = activeDevice
        engine.stop()
        do {
            try configure(target.id, session)
        } catch {
            stopCapture()
            deviceNotice = "Microphone capture stopped: \(error.localizedDescription)"
            return
        }
        activeDevice = target
        if let previous, previous.id != target.id {
            selectedInput = target   // not persisted: the saved choice is restored on next launch
            deviceNotice = "Microphone '\(previous.name)' disconnected — using '\(target.name)'."
        }
    }
```
- `configureEngine(deviceID:session:)` — add the device binding before reading the format:
```swift
    nonisolated private func configureEngine(deviceID: AudioDeviceID, session: SessionAudioStream) throws {
        engine.inputNode.removeTap(onBus: 0)
        let inputNode = engine.inputNode
        guard let unit = inputNode.audioUnit else {
            throw AudioError.engineStartFailed(NSError(domain: "AudioManager", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Input node has no audio unit"]))
        }
        try CoreAudioDevices.setCurrentDevice(deviceID, on: unit)
        let captureFormat = inputNode.outputFormat(forBus: 0)   // read AFTER binding: the rate may change
        guard captureFormat.sampleRate > 0, captureFormat.channelCount > 0 else {
            throw AudioError.engineStartFailed(NSError(domain: "AudioManager", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Device \(deviceID) reports no input format"]))
        }
        // … MicTap + installTap exactly as in Task 2 …
        engine.prepare()
        do { try engine.start() } catch { inputNode.removeTap(onBus: 0); throw AudioError.engineStartFailed(error) }
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `just test-only AudioManagerInputChoiceTests AudioManagerSwitchTests AudioManagerTests`
Expected: PASS.

- [ ] **Step 5: Surface notices and resync the picker in the view model**

`AudioViewModel.swift`:
```swift
    func selectInput(_ device: AudioDevice) {
        do {
            try audioManager.selectInput(device)
        } catch {
            selectedInput = audioManager.selectedInput   // picker back to the device actually in use
            errorAlert = AlertItem(title: "Microphone", message: error.localizedDescription, action: nil)
        }
    }
```
and in `bindAudioManager()`:
```swift
        audioManager.$deviceNotice
            .compactMap { $0 }
            .sink { [weak self] notice in
                self?.errorAlert = AlertItem(title: "Microphone", message: notice, action: nil)
            }
            .store(in: &cancellables)
```

- [ ] **Step 6: Build and run the unit tier**

Run: `just build && just test`
Expected: `** BUILD SUCCEEDED **`, unit tier PASS.

- [ ] **Step 7: Commit**

```bash
git add TranslateCall/Core/Audio/AudioManager.swift TranslateCall/Core/Audio/AudioError.swift \
        TranslateCall/Features/Main/AudioViewModel.swift TranslateCallTests/AudioManagerTests.swift
git commit -m "fix(audio): apply the selected mic and hot-swap it mid-session (A5, A5b)

The engine input unit is bound to selectedInput; changing mic during a
session reconfigures the engine on the same session stream, reverting on
failure; an unplugged mic falls back to the default with a notice."
```

---

### Task 7: Incoming status banner and Retry in the UI (REQ-C-36)

**Files:**
- Create: `TranslateCall/Features/Main/IncomingStatusBanner.swift`
- Modify: `TranslateCall/Features/Main/AudioViewModel.swift` (`incomingStatus`, `retryIncoming`)
- Modify: `TranslateCall/Features/ContentView.swift:51-53` (above `TranscriptionView`)
- Modify: `TranslateCall/Features/MenuBar/MenuBarPopoverView.swift:28-34` (below `StatusBadgeView`)
- Test: `TranslateCallTests/IncomingStatusBannerTests.swift`

**Interfaces:**
- Consumes: `IncomingStatus`, `IncomingStopReason.message` (Task 1); `AudioCoordinator.incomingStatus`, `.retryIncoming()` (Task 5).
- Produces: `struct IncomingStatusBanner: View { let status: IncomingStatus; let onRetry: () -> Void; static func text(for: IncomingStatus) -> String?; static func showsRetry(_: IncomingStatus) -> Bool }`, `AudioViewModel.incomingStatus`, `AudioViewModel.retryIncoming()`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import TranslateCall

@Suite("IncomingStatusBanner") @MainActor
struct IncomingStatusBannerTests {
    @Test("hidden when idle or active")
    func hidden() {
        #expect(IncomingStatusBanner.text(for: .idle) == nil)
        #expect(IncomingStatusBanner.text(for: .active) == nil)
    }

    @Test("texts and Retry visibility per status")
    func texts() {
        #expect(IncomingStatusBanner.text(for: .disabled) == "Incoming off — choose the call app in Setup")
        #expect(IncomingStatusBanner.text(for: .starting) == "Connecting to call audio…")
        let stopped = IncomingStatus.stopped(.targetNotFound(bundleID: "us.zoom.xos"))
        #expect(IncomingStatusBanner.text(for: stopped) == "Incoming stopped: The call app (us.zoom.xos) is not running.")
        #expect(IncomingStatusBanner.showsRetry(stopped))
        #expect(!IncomingStatusBanner.showsRetry(.disabled))
        #expect(!IncomingStatusBanner.showsRetry(.starting))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `just test-only IncomingStatusBannerTests`
Expected: build FAILS — `cannot find 'IncomingStatusBanner' in scope`.

- [ ] **Step 3: Implement**

`TranslateCall/Features/Main/IncomingStatusBanner.swift`:
```swift
import SwiftUI

/// One-line incoming pipeline status with Retry (F8.5.1 REQ-C-36). Renders nothing when idle/active.
struct IncomingStatusBanner: View {
    let status: IncomingStatus
    let onRetry: () -> Void

    static func text(for status: IncomingStatus) -> String? {
        switch status {
        case .idle, .active: return nil
        case .disabled: return "Incoming off — choose the call app in Setup"
        case .starting: return "Connecting to call audio…"
        case .stopped(let reason): return "Incoming stopped: \(reason.message)"
        }
    }

    static func showsRetry(_ status: IncomingStatus) -> Bool {
        if case .stopped = status { return true }
        return false
    }

    var body: some View {
        if let text = Self.text(for: status) {
            HStack(spacing: 6) {
                Image(systemName: Self.showsRetry(status) ? "exclamationmark.triangle.fill" : "speaker.slash")
                    .foregroundStyle(Self.showsRetry(status) ? .orange : .secondary)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if Self.showsRetry(status) {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
```

`AudioViewModel.swift`: add `@Published private(set) var incomingStatus: IncomingStatus = .idle`, bind `coordinator.$incomingStatus.assign(to: &$incomingStatus)` in `bindCoordinator()`, and:
```swift
    func retryIncoming() {
        coordinator.retryIncoming()
    }
```

`ContentView.swift` — immediately before `TranscriptionView(`:
```swift
            IncomingStatusBanner(status: viewModel.incomingStatus) { viewModel.retryIncoming() }
```
`MenuBarPopoverView.swift` — immediately after the `StatusBadgeView(...)` call:
```swift
            IncomingStatusBanner(status: viewModel.incomingStatus) { viewModel.retryIncoming() }
```

- [ ] **Step 4: Run to verify it passes**

Run: `just test-only IncomingStatusBannerTests && just build`
Expected: PASS, `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add TranslateCall/Features TranslateCallTests/IncomingStatusBannerTests.swift
git commit -m "feat(ui): incoming status banner with Retry (F8.5.1)"
```

---

### Task 8: Integration tests with BlackHole as a controlled microphone (A5, A5b, NFR-C-01)

**Files:**
- Create: `TranslateCallTests/Support/BlackHolePlayer.swift`
- Create: `TranslateCallTests/Support/TemporaryAggregateDevice.swift`
- Create: `TranslateCallTests/Support/BufferLog.swift`
- Create: `TranslateCallTests/Integration/MicCaptureIntegrationTests.swift`
- Modify: `TranslateCallTests/Integration/Prerequisites.swift` (add `requireMicrophoneAuthorization`, `requireBlackHole`)

**Interfaces:**
- Consumes: `AudioManager.selectInput/startCapture/stopCapture/activeInputDeviceID/inputDevices` (Tasks 2, 6), `CoreAudioDevices.setCurrentDevice` (Task 3), `MicTap.rms` (Task 2), `requirePrerequisite`, `Fixtures` (F8.5.0), `waitUntil` (Task 2).
- Produces: test-only helpers `BlackHolePlayer(fixtureURL:deviceID:)`, `TemporaryAggregateDevice(wrapping:)` with `.uid`, `BufferLog(_:)` with `.loudCount(since:)`, `.gapAround(_:)`, `.finished`.

- [ ] **Step 1: Write the helpers**

`TranslateCallTests/Support/BlackHolePlayer.swift`:
```swift
import AVFoundation
import CoreAudio
@testable import TranslateCall

/// Loops a fixture WAV into an output device (BlackHole) so a capture test hears known audio.
@MainActor
final class BlackHolePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    init(fixtureURL: URL, deviceID: AudioDeviceID) throws {
        let file = try AVAudioFile(forReading: fixtureURL)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw MissingPrerequisite(description: "could not allocate buffer for \(fixtureURL.lastPathComponent)")
        }
        try file.read(into: buffer)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        engine.prepare()
        guard let unit = engine.outputNode.audioUnit else {
            throw MissingPrerequisite(description: "output node has no audio unit")
        }
        try CoreAudioDevices.setCurrentDevice(deviceID, on: unit)
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}
```

`TranslateCallTests/Support/TemporaryAggregateDevice.swift`:
```swift
import CoreAudio
import Foundation

/// A private (this process only) aggregate device wrapping one sub-device: a second, distinct
/// input device that hears exactly what the sub-device hears. Destroyed on deinit.
final class TemporaryAggregateDevice {
    let id: AudioDeviceID
    let uid: String

    init(wrapping subDeviceUID: String) throws {
        uid = "com.spbarber.TranslateCall.tests.aggregate.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TranslateCall Test Input",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: subDeviceUID]],
            kAudioAggregateDeviceMainSubDeviceKey: subDeviceUID,
        ]
        var newID = AudioDeviceID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newID)
        guard status == noErr, newID != kAudioObjectUnknown else {
            throw MissingPrerequisite(description: "could not create aggregate device over \(subDeviceUID) (OSStatus \(status))")
        }
        id = newID
    }

    deinit {
        AudioHardwareDestroyAggregateDevice(id)
    }
}
```

`TranslateCallTests/Support/BufferLog.swift`:
```swift
import AVFoundation
@testable import TranslateCall

/// Consumes a capture stream for the whole test (one iterator, never cancelled mid-test) and
/// records when each buffer arrived and how loud it was.
@MainActor
final class BufferLog {
    struct Entry { let at: ContinuousClock.Instant; let rms: Float }
    private(set) var entries: [Entry] = []
    private(set) var finished = false
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<AVAudioPCMBuffer>) {
        task = Task { @MainActor [weak self] in
            for await buffer in stream {
                self?.entries.append(Entry(at: .now, rms: MicTap.rms(buffer)))
            }
            self?.finished = true
        }
    }

    func loudCount(since start: ContinuousClock.Instant, threshold: Float = -50) -> Int {
        entries.filter { $0.at >= start && $0.rms > threshold }.count
    }

    /// Time between the last buffer before `instant` and the first buffer after it.
    func gapAround(_ instant: ContinuousClock.Instant) -> Duration? {
        guard let before = entries.last(where: { $0.at < instant }),
              let after = entries.first(where: { $0.at >= instant }) else { return nil }
        return after.at - before.at
    }

    func cancel() { task?.cancel() }
}
```

Append to `TranslateCallTests/Integration/Prerequisites.swift`:
```swift
/// Microphone (TCC) permission for the test host — required to open any input device, BlackHole included.
func requireMicrophoneAuthorization() async throws {
    var status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .notDetermined {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        status = AVCaptureDevice.authorizationStatus(for: .audio)
    }
    try requirePrerequisite(status == .authorized, "Microphone permission for TranslateCall (status \(status.rawValue))")
}

/// BlackHole 2ch as both a playback target and a capture source.
func requireBlackHole(in devices: [AudioDevice]) throws -> AudioDevice {
    guard let device = devices.first(where: { $0.isBlackHole && $0.hasInput }) else {
        try requirePrerequisite(false, "BlackHole 2ch audio driver (brew install blackhole-2ch)")
        throw MissingPrerequisite(description: "BlackHole 2ch")
    }
    return device
}
```

- [ ] **Step 2: Write the integration tests**

`TranslateCallTests/Integration/MicCaptureIntegrationTests.swift`:
```swift
import AVFoundation
import Testing
@testable import TranslateCall

extension IntegrationTests {
    @Suite("Mic capture (BlackHole as controlled mic)", .serialized) @MainActor
    struct MicCaptureIntegrationTests {

        private func fixtureURL() throws -> URL {
            try Fixtures.url(for: #require(Fixtures.lang("en").first))
        }

        private func isolatedDefaults() -> UserDefaults {
            UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        }

        @Test("the selected input device is applied to the engine and its audio arrives (A5)")
        func selectedDeviceIsUsed() async throws {
            try await requireMicrophoneAuthorization()
            let manager = AudioManager(defaults: isolatedDefaults())
            let blackHole = try requireBlackHole(in: manager.inputDevices)

            try manager.selectInput(blackHole)
            let log = BufferLog(try await manager.startCapture())
            defer { log.cancel(); manager.stopCapture() }
            #expect(manager.activeInputDeviceID == blackHole.id)

            let player = try BlackHolePlayer(fixtureURL: try fixtureURL(), deviceID: blackHole.id)
            defer { player.stop() }
            let start = ContinuousClock.now
            #expect(await waitUntil(timeout: .seconds(3)) { log.loudCount(since: start) > 0 },
                    "no audio above -50 dBFS from BlackHole within 3 s")
        }

        @Test("switching mic mid-session keeps the same stream delivering audio (A5b, ≤ 500 ms gap)")
        func hotSwapKeepsStream() async throws {
            try await requireMicrophoneAuthorization()
            let probe = AudioManager(defaults: isolatedDefaults())
            let blackHole = try requireBlackHole(in: probe.inputDevices)
            let aggregate = try TemporaryAggregateDevice(wrapping: blackHole.uid)

            let manager = AudioManager(defaults: isolatedDefaults())   // enumerates after the aggregate exists
            let aggregateDevice = try #require(manager.inputDevices.first { $0.uid == aggregate.uid },
                                               "private aggregate device not visible in inputDevices")
            let player = try BlackHolePlayer(fixtureURL: try fixtureURL(), deviceID: blackHole.id)
            defer { player.stop() }

            try manager.selectInput(aggregateDevice)
            let log = BufferLog(try await manager.startCapture())
            defer { log.cancel(); manager.stopCapture() }
            let start = ContinuousClock.now
            #expect(await waitUntil(timeout: .seconds(3)) { log.loudCount(since: start) > 0 })

            let switchAt = ContinuousClock.now
            try manager.selectInput(blackHole)

            #expect(manager.activeInputDeviceID == blackHole.id)
            #expect(await waitUntil(timeout: .seconds(3)) { log.loudCount(since: switchAt) > 0 },
                    "no audio on the same stream after switching to BlackHole")
            #expect(!log.finished)
            let gap = try #require(log.gapAround(switchAt))
            #expect(gap <= .milliseconds(500), "hot swap gap \(gap) exceeds 500 ms (NFR-C-01)")
        }

        @Test("Stop → Start gives a new live stream and ends the old one")
        func stopStartGivesFreshStream() async throws {
            try await requireMicrophoneAuthorization()
            let manager = AudioManager(defaults: isolatedDefaults())
            let blackHole = try requireBlackHole(in: manager.inputDevices)
            let player = try BlackHolePlayer(fixtureURL: try fixtureURL(), deviceID: blackHole.id)
            defer { player.stop() }
            try manager.selectInput(blackHole)

            let first = BufferLog(try await manager.startCapture())
            manager.stopCapture()
            #expect(await waitUntil(timeout: .seconds(2)) { first.finished })

            let second = BufferLog(try await manager.startCapture())
            defer { second.cancel(); manager.stopCapture() }
            let start = ContinuousClock.now
            #expect(await waitUntil(timeout: .seconds(3)) { second.loudCount(since: start) > 0 })
        }
    }
}
```

- [ ] **Step 3: Run the integration tier**

Run: `just test-integration`
Expected: the three `MicCaptureIntegrationTests` PASS alongside the existing 13. If the hot-swap test fails because the aggregate is not visible, check `CoreAudioDevices.allDevices()` sees it (private aggregates are visible to the creating process); do **not** weaken the assertion — record the failure and stop to discuss (design §6 risk).

- [ ] **Step 4: Commit**

```bash
git add TranslateCallTests/Support/BlackHolePlayer.swift TranslateCallTests/Support/TemporaryAggregateDevice.swift \
        TranslateCallTests/Support/BufferLog.swift TranslateCallTests/Integration/MicCaptureIntegrationTests.swift \
        TranslateCallTests/Integration/Prerequisites.swift
git commit -m "test(integration): mic selection and hot swap with BlackHole as a controlled mic"
```

---

### Task 9: Static-analysis gate, hygiene sweep, docs and manual verification

**Files:**
- Modify: `.opengrep/rules/swift-audio.yml` (`buffer-nocopy-escape` → `ERROR`)
- Modify: `.opengrep/README.md` (severity table)
- Modify: any file under `TranslateCall/Core/Audio/` still reported by `just scan`
- Modify: `specs/m8.5-stabilization/backlog.md` (mark F8.5.1 items done)
- Modify: this file (manual checklist results)

- [ ] **Step 1: Promote the rule**

In `.opengrep/rules/swift-audio.yml`, rule `buffer-nocopy-escape`: `severity: ERROR`. Update the rule's row in `.opengrep/README.md` to `ERROR (F8.5.1)`.

- [ ] **Step 2: Scan and fix remaining Core/Audio findings**

Run: `just scan 2>&1 | tee build/logs/scan.log; grep -A3 "Core/Audio/" build/logs/scan.log`
Expected: `✓ no blocking findings` and **no** findings under `TranslateCall/Core/Audio/` for `asyncstream-unbounded`, `asyncstream-force-unwrap`, `nonisolated-unsafe-justified`. For any left: replace `AsyncStream { … }` with `AsyncStream.makeStream(of:bufferingPolicy:)`, remove `cont!`, or add a `// SAFETY:` line directly above the `nonisolated(unsafe)` explaining why it is race-free (e.g. `HalfDuplexManager.swift`, `DeviceMonitor.swift` if reported). Re-run until clean for `Core/Audio`.

- [ ] **Step 3: Lint**

Run: `just lint`
Expected: exit 0 (no warnings in strict mode).

- [ ] **Step 4: Update the backlog**

In `specs/m8.5-stabilization/backlog.md`, set the "Guard in place" column for A1, A1b, A2, A4, A5, A5b, T1 to `fixed in F8.5.1 (<PR #>)`, with the tests that now pin each (e.g. A1 → `AudioCoordinatorTests.restartGivesFreshIncomingStream`, A5b → `MicCaptureIntegrationTests.hotSwapKeepsStream`).

- [ ] **Step 5: Commit**

```bash
git add .opengrep specs/m8.5-stabilization/backlog.md TranslateCall
git commit -m "chore(scan): buffer-nocopy-escape is now an ERROR; Core/Audio scan-clean"
```

- [ ] **Step 6: Manual checklist (needs Screen Recording + a real call app)**

Build and run the app (`just build`, then open `build/DerivedData/Build/Products/Debug/TranslateCall.app`). Record date and result for each line in this file:

| # | Scenario | Expected | Result |
|---|----------|----------|--------|
| M1 | Zoom or FaceTime selected → Start → speak from the remote side → Stop → Start → speak again | Incoming translates both times | |
| M2 | During a session, quit the call app | Banner "Incoming stopped: …"; outgoing still translates into BlackHole | |
| M3 | Reopen the call app → Retry | Banner disappears, incoming translates | |
| M4 | Unplug the selected USB mic / disconnect AirPods mid-session | Alert "Microphone '…' disconnected — using '…'", outgoing continues | |
| M5 | Quit the call app, then Start | Banner `targetNotFound` with Retry; open app → Retry works | |
| M6 | Change mic in the picker mid-session; include a mono↔stereo mic swap | Outgoing keeps working on the new mic without Stop/Start | |

- [ ] **Step 7: Full gate**

Run: `just pr`
Expected: build → check → test → test-integration all pass; `local/just-pr` status = success on HEAD; PR created against `main` with the template checklist filled (spec link, tests, `just pr`, manual checklist M1–M6).
