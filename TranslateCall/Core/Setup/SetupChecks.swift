import Combine
import CoreAudio
import Foundation

// MARK: - Check outcomes

/// Why a basic check failed (REQ-FR-40…43).
nonisolated enum CheckFailure: Equatable, Sendable {
    case microphoneOff
    case noBlackHole
    case busy
    case notReceived
    case callRunning
    case other(String)

    var message: String {
        switch self {
        case .microphoneOff: String(localized: "Microphone access is off")
        case .noBlackHole: String(localized: "BlackHole 2ch not found")
        case .busy: String(localized: "Another app is sending audio to BlackHole — close it and try again")
        case .notReceived: String(localized: "BlackHole isn't receiving audio")
        case .callRunning: String(localized: "Available when no call is running")
        case .other(let message): message
        }
    }
}

/// A check's lifecycle: idle, running, passed, or failed with its reason (REQ-FR-43).
nonisolated enum CheckState: Equatable, Sendable {
    case idle
    case running
    case passed
    case failed(CheckFailure)
}

// MARK: - SetupChecks

/// The step-4 microphone meter and route test (REQ-FR-40…43, 57b), composed over `LevelSource`s,
/// a `PhrasePlayer` and an injected `Clock`, so tests drive it with fakes and a test clock.
@MainActor
final class SetupChecks: ObservableObject {

    /// Peak level of the mic check's latest sample, for the level meter (REQ-FR-40).
    @Published private(set) var micLevel: Float = LevelMeter.silence
    @Published private(set) var micState: CheckState = .idle
    @Published private(set) var routeState: CheckState = .idle

    private let micSource: () throws -> any LevelSource
    private let blackHoleSource: (AudioDeviceID) throws -> any LevelSource
    private let phrasePlayer: any PhrasePlayer
    private let clock: any Clock<Duration>
    private let readPermissions: () -> PermissionState
    private let readBlackHole: () -> AudioDeviceID?
    private let readCallRunning: () -> Bool

    private var micListener: (any LevelSource)?
    private var micTask: Task<Void, Never>?
    private var micGeneration = 0
    private var routeRun: Task<Void, Never>?
    private var routeGeneration = 0
    /// Each check's verdict before its current run: a cancelled run goes back to it.
    private var micVerdict: CheckState = .idle
    private var routeVerdict: CheckState = .idle

    /// Thresholds from the spec (REQ-FR-40/41): mic −40 dBFS for 300 ms; route baseline 300 ms,
    /// then −70 dBFS sustained 200 ms within 3 s of playback start.
    nonisolated fileprivate static let micThreshold: Float = -40
    nonisolated fileprivate static let routeThreshold: Float = -70
    nonisolated private static let micSustain = Duration.milliseconds(300)
    nonisolated fileprivate static let routeSustain = Duration.milliseconds(200)
    nonisolated fileprivate static let baselineWindow = Duration.milliseconds(300)
    nonisolated private static let routeTimeout = Duration.seconds(3)

    init(
        micSource: @escaping () throws -> any LevelSource,
        blackHoleSource: @escaping (AudioDeviceID) throws -> any LevelSource,
        phrasePlayer: any PhrasePlayer,
        clock: any Clock<Duration> = ContinuousClock(),
        permissions: @escaping () -> PermissionState = PermissionState.current,
        blackHole: @escaping () -> AudioDeviceID? = { BlackHoleDevice.find() },
        callRunning: @escaping () -> Bool
    ) {
        self.micSource = micSource
        self.blackHoleSource = blackHoleSource
        self.phrasePlayer = phrasePlayer
        self.clock = clock
        self.readPermissions = permissions
        self.readBlackHole = blackHole
        self.readCallRunning = callRunning
    }

    /// Sidebar state of step 4: done when a check passed, attention when one failed (REQ-FR-01).
    var testStatus: SetupStepStatus {
        if micState == .passed || routeState == .passed { return .done }
        if case .failed = micState { return .attention }
        if case .failed = routeState { return .attention }
        return .todo
    }

    // MARK: Microphone check (REQ-FR-40)

    /// Starts metering the microphone; passes at −40 dBFS sustained 300 ms and keeps metering
    /// until `stopMicCheck`. Fails early while a call runs or the microphone is off (REQ-FR-57b).
    func startMicCheck() {
        guard micTask == nil else { return }
        if readCallRunning() { micState = .failed(.callRunning); return }
        guard readPermissions().microphone == .granted else {
            micState = .failed(.microphoneOff)
            return
        }
        let listener: any LevelSource
        let stream: AsyncStream<LevelSample>
        do {
            listener = try micSource()
            stream = try listener.start()
        } catch {
            micState = .failed(.other(Self.message(for: error)))
            return
        }
        micListener = listener
        if micState != .running { micVerdict = micState }
        micState = .running
        micGeneration += 1
        let generation = micGeneration
        micTask = Task { [weak self] in
            var detector = SustainedLevelDetector(
                threshold: Self.micThreshold, minDuration: Self.micSustain
            )
            for await sample in stream {
                guard let self else { return }
                self.micLevel = sample.dbfs
                if self.micState == .running, detector.feed(sample) {
                    self.micState = .passed
                }
            }
            if let self, self.micGeneration == generation { self.stopMicCheck() }
        }
    }

    /// Stops the meter; keeps the last verdict until a new start or `cancelAll`.
    func stopMicCheck() {
        micGeneration += 1
        micTask?.cancel()
        micTask = nil
        micListener?.stop()
        micListener = nil
        micLevel = LevelMeter.silence
    }

    // MARK: Route check (REQ-FR-41, 42, 57b)

    /// Plays the fixed phrase into BlackHole 2ch while a listener verifies it: 300 ms quiet
    /// baseline, then pass at −70 dBFS sustained 200 ms within 3 s of playback start.
    func runRouteCheck() async {
        if let previous = cancelRouteRun() { await previous.value }
        if readCallRunning() { routeState = .failed(.callRunning); return }
        guard readPermissions().microphone == .granted else {
            routeState = .failed(.microphoneOff)
            return
        }
        guard let deviceID = readBlackHole() else {
            routeState = .failed(.noBlackHole)
            return
        }

        routeGeneration += 1
        let generation = routeGeneration
        let run = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRouteCheck(deviceID: deviceID, generation: generation)
        }
        routeRun = run
        await run.value
        if routeGeneration == generation { routeRun = nil }
    }

    /// Cancels every running check and releases the devices (REQ-FR-57). The verdicts stay, so the
    /// sidebar keeps step 4's state; a check cancelled mid-run goes back to its previous verdict.
    func cancelAll() {
        _ = cancelRouteRun()
        stopMicCheck()
        if micState == .running { micState = micVerdict }
    }

    /// Cancels the route run; from here on it writes nothing (generation), so its state goes back
    /// to the previous verdict now. Returns the run to wait for.
    private func cancelRouteRun() -> Task<Void, Never>? {
        routeGeneration += 1
        let run = routeRun
        run?.cancel()
        routeRun = nil
        if routeState == .running { routeState = routeVerdict }
        return run
    }

    /// Starts the 3 s deadline and the phrase; both report into `sink`.
    private func startPlayback(
        deviceID: AudioDeviceID, sink: AsyncStream<RouteEvent>.Continuation
    ) -> (timer: Task<Void, Never>, player: Task<Void, Never>) {
        let clock = clock, phrasePlayer = phrasePlayer
        let timer = Task {
            if (try? await clock.sleep(for: Self.routeTimeout)) != nil { sink.yield(.timeout) }
        }
        let player = Task {
            do { try await phrasePlayer.play(on: deviceID) } catch is CancellationError {} catch {
                sink.yield(.playerFailed(Self.message(for: error)))
            }
        }
        return (timer, player)
    }

    /// One event loop over the listener's samples, the baseline deadline, the 3 s deadline and
    /// the phrase player's failure, so the verdict needs no task-group racing. All tasks run on
    /// the MainActor; the listener is stopped and every task cancelled before returning.
    private func performRouteCheck(deviceID: AudioDeviceID, generation: Int) async {
        let listener: any LevelSource
        let stream: AsyncStream<LevelSample>
        do {
            listener = try blackHoleSource(deviceID)
            stream = try listener.start()
        } catch {
            routeState = .failed(.other(Self.message(for: error)))
            return
        }
        if routeState != .running { routeVerdict = routeState }
        routeState = .running

        let verdict = await routeEvents(deviceID: deviceID, stream: stream, listener: listener)
        // A cancelled run writes nothing: `cancelRouteRun` already restored the previous verdict.
        guard generation == routeGeneration, !Task.isCancelled else { return }
        routeState = verdict ?? .failed(.notReceived)   // the listener's stream ended on its own
    }

    /// Consumes the route events; returns the final verdict, or nil when the listener's stream
    /// ended on its own without one.
    private func routeEvents(
        deviceID: AudioDeviceID, stream: AsyncStream<LevelSample>, listener: any LevelSource
    ) async -> CheckState? {
        let clock = clock
        let (events, sink) = AsyncStream.makeStream(of: RouteEvent.self)
        let forwarder = Task {
            for await sample in stream { sink.yield(.sample(sample)) }
            sink.finish()
        }
        // BlackHole may deliver no samples at all while nothing plays into it, so the baseline's
        // sample-duration completion would never happen: time the 300 ms quiet window on the
        // clock (REQ-FR-42) and start playback when it elapses without a loud sample.
        let baselineTimer = Task {
            if (try? await clock.sleep(for: Self.baselineWindow)) != nil { sink.yield(.baselineElapsed) }
        }
        var timer: Task<Void, Never>?
        var player: Task<Void, Never>?
        defer {
            forwarder.cancel()
            baselineTimer.cancel()
            timer?.cancel()
            player?.cancel()
            listener.stop()
        }

        var judge = RouteJudge()
        var verdict: CheckState?
        var baselineDone = false
        loop: for await event in events {
            switch event {
            case .sample(let sample):
                let result = judge.feed(sample)
                if result == .baselineDone, !baselineDone {
                    baselineDone = true
                    baselineTimer.cancel()
                    (timer, player) = startPlayback(deviceID: deviceID, sink: sink)
                }
                verdict = result.state
            case .baselineElapsed:
                // Exactly once: the quiet window elapsed without samples, so playback starts
                // anyway; a late timer after a sample-based completion is ignored.
                if !baselineDone {
                    baselineDone = true
                    _ = judge.elapse()
                    (timer, player) = startPlayback(deviceID: deviceID, sink: sink)
                }
            case .timeout:
                verdict = .failed(.notReceived)
            case .playerFailed(let message):
                verdict = .failed(.other(message))
            }
            if verdict != nil { break loop }
        }
        return verdict
    }

    nonisolated private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

// MARK: - Route helpers

private enum RouteEvent {
    case sample(LevelSample)
    case baselineElapsed
    case timeout
    case playerFailed(String)
}

/// The sample-side rules: 300 ms quiet baseline (REQ-FR-42), then sustained detection (REQ-FR-41).
private struct RouteJudge {
    enum Verdict {
        case pending, baselineDone, busy, passed

        /// The final check state, or nil while the run goes on.
        var state: CheckState? {
            switch self {
            case .busy: .failed(.busy)
            case .passed: .passed
            case .pending, .baselineDone: nil
            }
        }
    }

    private var detector = SustainedLevelDetector(threshold: SetupChecks.routeThreshold,
                                                  minDuration: SetupChecks.routeSustain)
    private var baseline: Duration = .zero

    mutating func feed(_ sample: LevelSample) -> Verdict {
        if baseline >= SetupChecks.baselineWindow { return detector.feed(sample) ? .passed : .pending }
        if sample.dbfs >= SetupChecks.routeThreshold { return .busy }
        baseline += sample.duration
        return baseline >= SetupChecks.baselineWindow ? .baselineDone : .pending
    }

    /// The clock reports the quiet window elapsed without samples: complete the baseline once,
    /// so later samples feed the detector instead of a window that already passed.
    mutating func elapse() -> Verdict {
        if baseline >= SetupChecks.baselineWindow { return .pending }
        baseline = SetupChecks.baselineWindow
        return .baselineDone
    }
}
