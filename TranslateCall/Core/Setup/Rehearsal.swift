import AVFoundation
import Combine
import CoreAudio
import Foundation

// MARK: - Host

/// What the rehearsal driver reads from the session (REQ-FR-52…54).
nonisolated struct RehearsalSnapshot: Equatable, Sendable {
    /// The microphone capture runs: "Preparing…" ends and the timers start.
    var isCapturing = false
    var isActive = false
    /// The rehearsal's first outgoing transcript entry; nil until the user said something.
    var firstOutgoing: TranscriptEntry?
    /// True until the last clause-split part is translated and spoken (REQ-CS-18).
    var isTranslating = false
    var isSpeaking = false
    /// A pipeline error routed to the rehearsal instead of the main window (REQ-FR-56).
    var error: String?
}

/// The session the rehearsal drives; `AudioCoordinator` conforms (design §6.1).
@MainActor
protocol RehearsalHost: AnyObject {
    /// Starts the real session outgoing only, in rehearsal mode.
    func startRehearsal(blackHole: AudioDeviceID) async
    /// Stops the session if a rehearsal is still running; no-op otherwise.
    func stopRehearsal() async
    var snapshot: RehearsalSnapshot { get }
    /// A fresh snapshot after every change, delivered on the main queue.
    var snapshots: AnyPublisher<RehearsalSnapshot, Never> { get }
}

// MARK: - Outcomes

/// Why a rehearsal failed (REQ-FR-53/54).
nonisolated enum RehearsalFailure: Equatable, Sendable {
    case notHeard
    case notReceived
    case preparingTooLong
    case pipeline(String)

    var message: String {
        switch self {
        case .notHeard: String(localized: "We didn't hear you — try again, a bit louder")
        case .notReceived: String(localized: "Your translation didn't reach BlackHole")
        case .preparingTooLong: String(localized: "Preparing is taking too long — try again")
        case .pipeline(let message): message
        }
    }
}

/// The rehearsal box's state (REQ-FR-50…55).
nonisolated enum RehearsalState: Equatable, Sendable {
    case unavailable(String)
    case ready
    case needsConsent
    case preparing
    case listening
    case translating(said: String)
    case passed(said: String, received: String)
    case failed(RehearsalFailure)

    /// The session is up (or coming up) for this rehearsal.
    var isRunning: Bool {
        switch self {
        case .preparing, .listening, .translating: true
        default: false
        }
    }
}

// MARK: - Rehearsal

/// Runs one rehearsal through the real outgoing session (REQ-FR-50…55, 57; design §6.3): a
/// BlackHole listener (recording) plus the host's snapshots, judged in one event loop on an
/// injected clock. The session and the listener are always released, also on `cancel()`.
@MainActor
final class Rehearsal: ObservableObject {

    @Published private(set) var state: RehearsalState = .ready

    private let host: any RehearsalHost
    private let makeListener: (AudioDeviceID) throws -> any LevelSource
    private let player: (any RecordingPlaying)?
    private let clock: any Clock<Duration>
    private let needsConsent: () -> Bool
    private let grantConsent: () -> Void
    private let readBlackHole: () -> AudioDeviceID?

    /// Why the rehearsal cannot run now; nil = available (REQ-FR-50).
    private var reason: String?
    /// The last outcome shown while idle: `.ready`, `.passed` or `.failed`.
    private var result: RehearsalState = .ready
    private var awaitingConsent = false
    private var run: Task<Void, Never>?
    private var runGeneration = 0
    /// What reached BlackHole during a passed rehearsal, for "Play" (REQ-FR-55). Memory only.
    private var recording: [AVAudioPCMBuffer] = []

    init(
        host: any RehearsalHost,
        listener: @escaping (AudioDeviceID) throws -> any LevelSource,
        player: (any RecordingPlaying)?,
        clock: any Clock<Duration> = ContinuousClock(),
        needsConsent: @escaping () -> Bool,
        grantConsent: @escaping () -> Void,
        blackHole: @escaping () -> AudioDeviceID? = { BlackHoleDevice.find() }
    ) {
        self.host = host
        self.makeListener = listener
        self.player = player
        self.clock = clock
        self.needsConsent = needsConsent
        self.grantConsent = grantConsent
        self.readBlackHole = blackHole
    }

    private var isBusy: Bool { run != nil || awaitingConsent }

    // MARK: Availability (REQ-FR-50, 57b)

    /// Why the rehearsal is unavailable, first match wins; nil when it can run.
    nonisolated static func availability(
        phase: SessionPhase, readiness: Readiness, blackHolePresent: Bool, microphone: PermissionStatus
    ) -> String? {
        if phase != .idle { return String(localized: "Available when no call is running") }
        if microphone != .granted { return String(localized: "Allow the microphone in step 1") }
        if !blackHolePresent { return String(localized: "Install BlackHole 2ch in step 2") }
        switch readiness.primary {
        case .download(let language): return String(localized: "Available once \(language) is downloaded")
        case .waitingForDownload: return String(localized: "Waiting for the download to finish")
        case .unsupportedPair: return String(localized: "This language pair isn't available")
        case .checking: return String(localized: "Checking languages…")
        default: return readiness.blockingReason
        }
    }

    /// Updates the availability; ignored while a rehearsal runs or asks for consent. A previous
    /// result comes back once the reason clears.
    func refresh(availability: String?) {
        reason = availability
        guard !isBusy else { return }
        showIdle()
    }

    // MARK: Actions

    /// Asks for Edge consent first when needed (REQ-FR-51), else starts the rehearsal.
    func rehearse() {
        guard !isBusy, reason == nil else { return }
        if needsConsent() {
            awaitingConsent = true
            state = .needsConsent
            return
        }
        startRun()
    }

    /// The wizard's own consent answer: accepting grants it and rehearses; never starts a call.
    func consent(accepted: Bool) {
        guard awaitingConsent else { return }
        awaitingConsent = false
        guard accepted else {
            showIdle()
            return
        }
        grantConsent()
        startRun()
    }

    /// Stops a running rehearsal and any playback, and waits for the session and listener to be
    /// released (REQ-FR-57). The last result and its recording stay (the sidebar keeps step 4's
    /// state); a cancelled run goes back to it. Only a new run replaces them.
    func cancel() async {
        awaitingConsent = false
        player?.stop()
        if let task = run {
            runGeneration += 1
            task.cancel()
            await task.value
            if run == task { run = nil }
        }
        showIdle()
    }

    /// Plays what reached BlackHole on the default output, after a pass only (REQ-FR-55).
    func playResult() {
        guard case .passed = state, !recording.isEmpty else { return }
        try? player?.play(recording)
    }

    // MARK: Run

    private func showIdle() {
        state = reason.map { .unavailable($0) } ?? result
    }

    private func startRun() {
        guard let deviceID = readBlackHole() else {
            result = .failed(.pipeline(CheckFailure.noBlackHole.message))
            showIdle()
            return
        }
        player?.stop()   // the previous result's playback: the run listens on BlackHole
        state = .preparing
        runGeneration += 1
        let generation = runGeneration
        run = Task { [weak self] in
            guard let self else { return }
            let verdict = await self.perform(deviceID: deviceID)
            guard self.runGeneration == generation else { return }   // cancelled: cancel() resets
            self.run = nil
            self.result = verdict ?? .ready
            self.showIdle()
        }
    }

    /// Listener on, session on, one event loop to a verdict, then both off. Returns nil when cancelled.
    private func perform(deviceID: AudioDeviceID) async -> RehearsalState? {
        let listener: any LevelSource
        let samples: AsyncStream<LevelSample>
        do {
            listener = try makeListener(deviceID)
            samples = try listener.start()
        } catch {
            return .failed(.pipeline((error as? LocalizedError)?.errorDescription ?? String(describing: error)))
        }
        let (events, sink) = AsyncStream.makeStream(of: RehearsalEvent.self)
        let forwarder = Task {
            for await sample in samples { sink.yield(.sample(sample)) }
        }
        let subscription = host.snapshots.sink { sink.yield(.snapshot($0)) }
        let timers = RehearsalTimers(clock: clock, sink: sink)
        timers.start(.preparing, after: RehearsalJudge.preparingCap)
        let host = host
        let starter = Task {
            guard !Task.isCancelled else { return }
            // Snapshots read before this point may carry a previous rehearsal's error: skipped.
            sink.yield(.hostStarting)
            await host.startRehearsal(blackHole: deviceID)
            sink.yield(.snapshot(host.snapshot))
        }

        let verdict = await judge(events, timers: timers)

        subscription.cancel()
        forwarder.cancel()
        timers.cancelAll()
        starter.cancel()
        await host.stopRehearsal()
        listener.stop()
        if case .passed = verdict {
            recording = listener.recording
        } else if verdict != nil {
            recording = []   // a new verdict replaces the last pass; a cancelled run keeps it
        }
        return verdict
    }

    /// The event loop: snapshots, listener samples and timers in arrival order, until a verdict.
    private func judge(_ events: AsyncStream<RehearsalEvent>, timers: RehearsalTimers) async -> RehearsalState? {
        var judge = RehearsalJudge()
        var hostStarted = false
        for await event in events {
            var step = RehearsalJudge.Step()
            switch event {
            case .hostStarting:
                hostStarted = true
            case .snapshot(let snapshot):
                guard hostStarted else { continue }
                step = judge.feed(snapshot)
            case .sample(let sample):
                judge.feed(sample)
            case .timer(let timer, let token):
                guard timers.isCurrent(timer, token: token) else { continue }
                timers.cancel(timer)
                step.verdict = judge.fire(timer)
            }
            if let verdict = step.verdict { return verdict }
            step.cancel.forEach(timers.cancel)
            step.start.forEach { timers.start($0.timer, after: $0.after) }
            if let display = step.display { state = display }
        }
        return nil
    }
}
