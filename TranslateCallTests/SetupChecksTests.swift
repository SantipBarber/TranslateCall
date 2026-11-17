import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import TranslateCall

// MARK: - Fakes

/// Scripted `LevelSource`: the test feeds `LevelSample`s and counts `stop()` calls. Samples yielded
/// before `start()` are buffered, so tests never race the checks' startup.
@MainActor
final class FakeLevelSource: LevelSource {
    private(set) var stopCount = 0
    private var stream: AsyncStream<LevelSample>
    private var continuation: AsyncStream<LevelSample>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream(of: LevelSample.self) }

    var recording: [AVAudioPCMBuffer] { [] }

    func start() throws -> AsyncStream<LevelSample> { stream }

    func stop() {
        stopCount += 1
        continuation.finish()
        (stream, continuation) = AsyncStream.makeStream(of: LevelSample.self) // ready for a restart
    }

    func yield(_ dbfs: Float, milliseconds: Int64) {
        continuation.yield(LevelSample(dbfs: dbfs, duration: .milliseconds(milliseconds)))
    }
}

/// Records every `play`, optionally throwing instead.
@MainActor
final class FakePhrasePlayer: PhrasePlayer {
    private(set) var playCount = 0
    private(set) var playedDevice: AudioDeviceID?
    var thrownError: (any Error)?

    func play(on device: AudioDeviceID) async throws {
        playCount += 1
        playedDevice = device
        if let thrownError { throw thrownError }
    }
}

// MARK: - Bundle

@MainActor
struct WorkingChecks {
    let mic: FakeLevelSource
    let blackHole: FakeLevelSource
    let player: FakePhrasePlayer
    let clock: TestClock
    let checks: SetupChecks
}

@MainActor
func makeWorkingChecks(
    permissions: @escaping () -> PermissionState = { .allGranted },
    blackHoleDevice: AudioDeviceID? = 42,
    callRunning: @escaping () -> Bool = { false }
) -> WorkingChecks {
    let mic = FakeLevelSource()
    let blackHole = FakeLevelSource()
    let player = FakePhrasePlayer()
    let clock = TestClock()
    let checks = SetupChecks(
        micSource: { mic },
        blackHoleSource: { _ in blackHole },
        phrasePlayer: player,
        clock: clock,
        permissions: permissions,
        blackHole: { blackHoleDevice },
        callRunning: callRunning
    )
    return WorkingChecks(mic: mic, blackHole: blackHole, player: player, clock: clock, checks: checks)
}

/// A route check running in a task; `finish()` never hangs: a stuck run is recorded and cancelled.
@MainActor
final class RouteRun {
    private(set) var isDone = false
    private var task: Task<Void, Never>?

    init(_ checks: SetupChecks) {
        task = Task { @MainActor in
            await checks.runRouteCheck()
            self.isDone = true
        }
    }

    func finish(_ checks: SetupChecks, sourceLocation: SourceLocation = #_sourceLocation) async {
        if await waitUntil({ self.isDone }) { return }
        Issue.record("route check did not finish", sourceLocation: sourceLocation)
        checks.cancelAll()
        task?.cancel()
    }
}

// MARK: - Tests

@Suite("SetupChecks (REQ-FR-40…43, 57b)", .serialized) @MainActor
struct SetupChecksTests {

    @Test("route check passes when the listener hears the phrase")
    func routePasses() async {
        let bundle = makeWorkingChecks()
        let run = RouteRun(bundle.checks)

        // Baseline: the first 300 ms stay below −70 dBFS; playback starts only after it.
        for _ in 0..<2 { bundle.blackHole.yield(-100, milliseconds: 100) }
        #expect(!(await waitUntil(timeout: .milliseconds(100)) { bundle.player.playCount > 0 }))
        bundle.blackHole.yield(-100, milliseconds: 100)
        #expect(await waitUntil { bundle.player.playCount == 1 })

        // The phrase reaches the listener: −60 dBFS sustained for 200 ms.
        bundle.blackHole.yield(-60, milliseconds: 150)
        bundle.blackHole.yield(-60, milliseconds: 150)

        await run.finish(bundle.checks)
        #expect(bundle.checks.routeState == .passed)
        #expect(bundle.player.playCount == 1)
        #expect(bundle.player.playedDevice == 42)
        #expect(bundle.blackHole.stopCount == 1)
    }

    @Test("route check fails busy when audio arrives during the baseline")
    func routeBusyBaseline() async {
        let bundle = makeWorkingChecks()
        let run = RouteRun(bundle.checks)
        bundle.blackHole.yield(-50, milliseconds: 100)

        await run.finish(bundle.checks)
        #expect(bundle.checks.routeState == .failed(.busy))
        #expect(bundle.blackHole.stopCount == 1)
        #expect(bundle.player.playCount == 0)
    }

    @Test("route check fails not received when nothing is heard within 3 s")
    func routeTimesOut() async {
        let bundle = makeWorkingChecks()
        let run = RouteRun(bundle.checks)
        for _ in 0..<3 { bundle.blackHole.yield(-100, milliseconds: 100) }
        #expect(await waitUntil { bundle.player.playCount == 1 && bundle.clock.sleeperCount == 1 })
        #expect(bundle.clock.pendingDeadlines == [.seconds(3)])

        bundle.clock.advance(by: .seconds(3))

        await run.finish(bundle.checks)
        #expect(bundle.checks.routeState == .failed(.notReceived))
        #expect(bundle.blackHole.stopCount == 1)
    }

    @Test("route check without BlackHole 2ch never builds a listener")
    func routeCheckWithoutBlackHole() async {
        let bundle = makeWorkingChecks(blackHoleDevice: nil)
        var sourceBuilt = false
        let checks = SetupChecks(
            micSource: { FakeLevelSource() },
            blackHoleSource: { _ in sourceBuilt = true; return FakeLevelSource() },
            phrasePlayer: bundle.player,
            clock: bundle.clock,
            permissions: { .allGranted },
            blackHole: { nil },
            callRunning: { false }
        )

        await checks.runRouteCheck()

        #expect(checks.routeState == .failed(.noBlackHole))
        #expect(!sourceBuilt)
        #expect(bundle.player.playCount == 0)
    }

    @Test("route and mic checks fail microphoneOff without permission")
    func routeMicOff() async {
        let bundle = makeWorkingChecks(
            permissions: { PermissionState(microphone: .denied, screenRecording: .granted) }
        )
        var sourceBuilt = false
        let checks = SetupChecks(
            micSource: { FakeLevelSource() },
            blackHoleSource: { _ in sourceBuilt = true; return FakeLevelSource() },
            phrasePlayer: bundle.player,
            clock: bundle.clock,
            permissions: { PermissionState(microphone: .denied, screenRecording: .granted) },
            blackHole: { 42 },
            callRunning: { false }
        )

        await checks.runRouteCheck()
        checks.startMicCheck()

        #expect(checks.routeState == .failed(.microphoneOff))
        #expect(checks.micState == .failed(.microphoneOff))
        #expect(!sourceBuilt)
        #expect(bundle.player.playCount == 0)
    }

    @Test("checks are unavailable while a call runs")
    func availabilityDuringCall() async {
        let bundle = makeWorkingChecks(callRunning: { true })
        var sourceBuilt = false
        let checks = SetupChecks(
            micSource: { FakeLevelSource() },
            blackHoleSource: { _ in sourceBuilt = true; return FakeLevelSource() },
            phrasePlayer: bundle.player,
            clock: bundle.clock,
            permissions: { .allGranted },
            blackHole: { 42 },
            callRunning: { true }
        )

        await checks.runRouteCheck()
        checks.startMicCheck()

        #expect(checks.routeState == .failed(.callRunning))
        #expect(checks.micState == .failed(.callRunning))
        #expect(!sourceBuilt)
        #expect(bundle.player.playCount == 0)
    }

    @Test("the listener is stopped on pass, failure and cancellation")
    func listenerAlwaysStopped() async {
        // Pass
        let passing = makeWorkingChecks()
        var run = RouteRun(passing.checks)
        for _ in 0..<3 { passing.blackHole.yield(-100, milliseconds: 100) }
        passing.blackHole.yield(-60, milliseconds: 250)
        await run.finish(passing.checks)
        #expect(passing.checks.routeState == .passed)
        #expect(passing.blackHole.stopCount == 1)

        // Failure
        let failing = makeWorkingChecks()
        run = RouteRun(failing.checks)
        failing.blackHole.yield(-50, milliseconds: 100)
        await run.finish(failing.checks)
        #expect(failing.checks.routeState == .failed(.busy))
        #expect(failing.blackHole.stopCount == 1)

        // Cancellation, while the 3 s deadline is pending
        let cancelled = makeWorkingChecks()
        run = RouteRun(cancelled.checks)
        for _ in 0..<3 { cancelled.blackHole.yield(-100, milliseconds: 100) }
        #expect(await waitUntil { cancelled.clock.sleeperCount == 1 })
        cancelled.checks.cancelAll()
        await run.finish(cancelled.checks)
        #expect(cancelled.checks.routeState == .idle)
        #expect(cancelled.blackHole.stopCount == 1)
        #expect(cancelled.clock.sleeperCount == 0)
    }

    @Test("a phrase-player error surfaces as .other with its message")
    func routePlayerError() async {
        let bundle = makeWorkingChecks()
        bundle.player.thrownError = SetupAudioError.noSystemVoice
        let run = RouteRun(bundle.checks)
        for _ in 0..<3 { bundle.blackHole.yield(-100, milliseconds: 100) }

        await run.finish(bundle.checks)
        #expect(bundle.checks.routeState == .failed(.other("No English system voice is installed")))
        #expect(bundle.blackHole.stopCount == 1)
    }

    @Test("mic check passes at −40 dBFS for 300 ms")
    func micPassesAtMinus40For300ms() async {
        let bundle = makeWorkingChecks()
        bundle.checks.startMicCheck()
        #expect(bundle.checks.micState == .running)

        bundle.mic.yield(-39, milliseconds: 200)
        #expect(await waitUntil { bundle.checks.micLevel == -39 })
        #expect(bundle.checks.micState == .running) // 200 ms is not yet 300 ms

        bundle.mic.yield(-39, milliseconds: 200)
        #expect(await waitUntil { bundle.checks.micState == .passed })
        #expect(bundle.checks.micLevel == -39)
        bundle.checks.stopMicCheck()
    }

    @Test("quiet audio keeps the mic check running; restarting works after a stop")
    func micQuietStaysRunning() async {
        let bundle = makeWorkingChecks()
        bundle.checks.startMicCheck()

        for _ in 0..<5 { bundle.mic.yield(-60, milliseconds: 100) }
        bundle.mic.yield(-61, milliseconds: 100)
        #expect(await waitUntil { bundle.checks.micLevel == -61 })
        #expect(bundle.checks.micState == .running)
        bundle.checks.stopMicCheck()

        bundle.checks.startMicCheck()
        bundle.mic.yield(-30, milliseconds: 400)
        #expect(await waitUntil { bundle.checks.micState == .passed })
        bundle.checks.stopMicCheck()
    }

    @Test("testStatus: done when a check passed, attention when one failed, else todo")
    func testStatusRules() async {
        let bundle = makeWorkingChecks()
        #expect(bundle.checks.testStatus == .todo)

        bundle.checks.startMicCheck()
        #expect(bundle.checks.testStatus == .todo)
        bundle.mic.yield(-39, milliseconds: 300)
        #expect(await waitUntil { bundle.checks.micState == .passed })
        #expect(bundle.checks.testStatus == .done)
        bundle.checks.stopMicCheck()

        let run = RouteRun(bundle.checks)
        bundle.blackHole.yield(-50, milliseconds: 100)
        await run.finish(bundle.checks)
        #expect(bundle.checks.routeState == .failed(.busy))
        #expect(bundle.checks.testStatus == .done) // a pass wins over a failure

        // Attention when only failures are visible.
        let failing = makeWorkingChecks(blackHoleDevice: nil)
        await failing.checks.runRouteCheck() // no BlackHole → immediate failure
        #expect(failing.checks.testStatus == .attention)
    }
}
