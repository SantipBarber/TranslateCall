import AVFoundation
import Combine
import CoreAudio
import Foundation
import Testing
@testable import TranslateCall

// MARK: - Fakes

/// Scripted session: tests set `snapshot`, which is published at once; start/stop are counted.
@MainActor
final class FakeRehearsalHost: RehearsalHost {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var startedDevice: AudioDeviceID?
    private let subject = PassthroughSubject<RehearsalSnapshot, Never>()

    var snapshot = RehearsalSnapshot() {
        didSet { subject.send(snapshot) }
    }

    var snapshots: AnyPublisher<RehearsalSnapshot, Never> { subject.eraseToAnyPublisher() }

    func startRehearsal(blackHole: AudioDeviceID) async {
        startCount += 1
        startedDevice = blackHole
    }

    func stopRehearsal() async { stopCount += 1 }
}

/// Counts `play` and `stop`.
@MainActor
final class FakeRecordingPlayer: RecordingPlaying {
    private(set) var playCount = 0
    private(set) var stopCount = 0
    func play(_ buffers: [AVAudioPCMBuffer]) throws { playCount += 1 }
    func stop() { stopCount += 1 }
}

@MainActor
final class ConsentBox {
    var needed = false
    private(set) var grants = 0
    func grant() { grants += 1; needed = false }
}

// MARK: - Bundle

@MainActor
struct RehearsalBundle {
    let host: FakeRehearsalHost
    let listener: FakeLevelSource
    let clock: TestClock
    let consent: ConsentBox
    let rehearsal: Rehearsal

    /// "Rehearse" → host started, the 90 s "Preparing…" cap registered.
    func begin(sourceLocation: SourceLocation = #_sourceLocation) async {
        rehearsal.rehearse()
        let started = await waitUntil(timeout: settle) {
            host.startCount == 1 && clock.pendingDeadlines == [.seconds(90)]
        }
        #expect(started, "rehearsal did not start", sourceLocation: sourceLocation)
        #expect(rehearsal.state == .preparing, sourceLocation: sourceLocation)
    }

    /// Capture runs: "Say a short sentence…" with the 15 s and 30 s timers from now.
    func capture(sourceLocation: SourceLocation = #_sourceLocation) async {
        let now = clock.now.offset
        host.snapshot = RehearsalSnapshot(isCapturing: true, isActive: true)
        let listening = await waitUntil(timeout: settle) {
            rehearsal.state == .listening
                && clock.pendingDeadlines == [now + .seconds(15), now + .seconds(30)]
        }
        #expect(listening, "capture not seen", sourceLocation: sourceLocation)
    }

    /// Publishes the session's view of the first sentence.
    func session(_ entry: TranscriptEntry?, translating: Bool = false, speaking: Bool = false) {
        host.snapshot = RehearsalSnapshot(isCapturing: true, isActive: true, firstOutgoing: entry,
                                          isTranslating: translating, isSpeaking: speaking)
    }

    func waitDeadlines(_ deadlines: [Duration], sourceLocation: SourceLocation = #_sourceLocation) async {
        let reached = await waitUntil(timeout: settle) { clock.pendingDeadlines == deadlines }
        #expect(reached, "deadlines \(clock.pendingDeadlines) != \(deadlines)", sourceLocation: sourceLocation)
    }

    func waitState(_ expected: RehearsalState, sourceLocation: SourceLocation = #_sourceLocation) async {
        let reached = await waitUntil(timeout: settle) { rehearsal.state == expected }
        #expect(reached, "state \(rehearsal.state) != \(expected)", sourceLocation: sourceLocation)
    }

    /// Waits for the run to end; a stuck run is recorded and cancelled (bounded), never hangs.
    func finish(sourceLocation: SourceLocation = #_sourceLocation) async {
        if await waitUntil(timeout: settle, { !rehearsal.state.isRunning && host.stopCount > 0 }) { return }
        Issue.record("rehearsal did not finish (\(rehearsal.state))", sourceLocation: sourceLocation)
        await boundedCancel(sourceLocation: sourceLocation)
    }

    /// `cancel()` in a task, waited for with a bound.
    func boundedCancel(sourceLocation: SourceLocation = #_sourceLocation) async {
        let done = ConsentBox()   // reused as a flag: `grant()` marks the cancel as returned
        let task = Task { @MainActor in
            await rehearsal.cancel()
            done.grant()
        }
        if !(await waitUntil(timeout: settle) { done.grants > 0 }) {
            Issue.record("cancel() did not return", sourceLocation: sourceLocation)
            task.cancel()
        }
    }

    /// Loud enough at BlackHole for the listener to pass (−70 dBFS for 200 ms).
    func hearTranslation() {
        listener.yield(-30, milliseconds: 150)
        listener.yield(-30, milliseconds: 150)
    }
}

@MainActor
func makeRehearsal(blackHole: AudioDeviceID? = 42, player: (any RecordingPlaying)? = nil) -> RehearsalBundle {
    let host = FakeRehearsalHost()
    let listener = FakeLevelSource()
    let clock = TestClock()
    let consent = ConsentBox()
    let rehearsal = Rehearsal(
        host: host,
        listener: { _ in listener },
        player: player,
        clock: clock,
        needsConsent: { consent.needed },
        grantConsent: { consent.grant() },
        blackHole: { blackHole }
    )
    return RehearsalBundle(host: host, listener: listener, clock: clock, consent: consent, rehearsal: rehearsal)
}

private func entry(_ original: String, _ translation: String? = nil) -> TranscriptEntry {
    var entry = TranscriptEntry(direction: .outgoing, original: original)
    entry.translation = translation
    return entry
}

// MARK: - Availability

@Suite("Rehearsal availability (REQ-FR-50, 57b)") @MainActor
struct RehearsalAvailabilityTests {

    private let ready = Readiness(primary: .start, primaryEnabled: true, cards: [])

    private func reason(phase: SessionPhase = .idle, readiness: Readiness? = nil, blackHole: Bool = true,
                        microphone: PermissionStatus = .granted) -> String? {
        Rehearsal.availability(phase: phase, readiness: readiness ?? ready,
                               blackHolePresent: blackHole, microphone: microphone)
    }

    private func readiness(_ primary: Readiness.Primary) -> Readiness {
        Readiness(primary: primary, primaryEnabled: false, cards: [])
    }

    @Test("first matching reason wins, nil when Start is allowed")
    func availabilityOrder() {
        #expect(reason() == nil)
        #expect(reason(phase: .running, microphone: .denied) == "Available when no call is running")
        #expect(reason(phase: .starting) == "Available when no call is running")
        #expect(reason(phase: .launching) == "Available when no call is running")
        #expect(reason(blackHole: false, microphone: .notDetermined) == "Allow the microphone in step 1")
        #expect(reason(readiness: readiness(.unsupportedPair), blackHole: false) == "Install BlackHole 2ch in step 2")
        #expect(reason(readiness: readiness(.download("Spanish"))) == "Available once Spanish is downloaded")
        #expect(reason(readiness: readiness(.waitingForDownload)) == "Waiting for the download to finish")
        #expect(reason(readiness: readiness(.unsupportedPair)) == "This language pair isn't available")
        #expect(reason(readiness: readiness(.checking)) == "Checking languages…")
        let blocked = Readiness(primary: .start, primaryEnabled: false, cards: [.microphoneOff])
        #expect(reason(readiness: blocked) == blocked.blockingReason)
    }
}

// MARK: - Driver

@Suite("Rehearsal driver (REQ-FR-51…55, 57)", .serialized) @MainActor
struct RehearsalTests {

    @Test("Edge consent is asked before anything starts")
    func consentAskedFirst() async {
        let bundle = makeRehearsal()
        bundle.consent.needed = true

        bundle.rehearsal.rehearse()

        #expect(bundle.rehearsal.state == .needsConsent)
        await mainQueueHop()
        #expect(bundle.host.startCount == 0)
        #expect(bundle.clock.sleeperCount == 0)
    }

    @Test("declining consent goes back to ready without starting")
    func consentDeclinedBackToReady() async {
        let bundle = makeRehearsal()
        bundle.consent.needed = true
        bundle.rehearsal.rehearse()

        bundle.rehearsal.consent(accepted: false)

        #expect(bundle.rehearsal.state == .ready)
        await mainQueueHop()
        #expect(bundle.consent.grants == 0)
        #expect(bundle.host.startCount == 0)
    }

    @Test("accepting consent grants it and runs the rehearsal")
    func consentAcceptedGrantsAndRuns() async {
        let bundle = makeRehearsal()
        bundle.consent.needed = true
        bundle.rehearsal.rehearse()

        bundle.rehearsal.consent(accepted: true)

        #expect(bundle.consent.grants == 1)
        #expect(bundle.rehearsal.state == .preparing)
        #expect(await waitUntil(timeout: settle) { bundle.host.startCount == 1 })
        #expect(bundle.host.startedDevice == 42)
        await bundle.boundedCancel()
    }

    @Test("passes 1.5 s after the first sentence is translated and spoken, heard at BlackHole")
    func passesAfterSettle() async {
        let bundle = makeRehearsal()
        await bundle.begin()
        await bundle.capture()
        bundle.hearTranslation()

        let first = entry("hello")
        bundle.session(first, translating: true)
        await bundle.waitState(.translating(said: "hello"))
        await bundle.waitDeadlines([.seconds(30)])   // the 15 s "not heard" timer is gone

        let translated = entry(first, "hola")
        bundle.session(translated, translating: true, speaking: true)
        bundle.session(translated)
        await bundle.waitDeadlines([.milliseconds(1500), .seconds(30)])
        bundle.clock.advance(by: .milliseconds(1400))
        await mainQueueHop()
        #expect(bundle.rehearsal.state == .translating(said: "hello"))
        bundle.clock.advance(by: .milliseconds(100))

        await bundle.finish()
        #expect(bundle.rehearsal.state == .passed(said: "hello", received: "hola"))
        #expect(bundle.host.stopCount == 1)
        #expect(bundle.listener.stopCount == 1)
        #expect(bundle.clock.sleeperCount == 0)
    }

    @Test("waits for every clause-split part; speaking again resets the settle")
    func waitsForAllParts() async {
        let bundle = makeRehearsal()
        await bundle.begin()
        await bundle.capture()
        bundle.hearTranslation()

        let first = entry("hello my friend")
        bundle.session(entry(first, "hola"), translating: true, speaking: true)   // part 1 spoken
        await bundle.waitState(.translating(said: "hello my friend"))
        bundle.clock.advance(by: .seconds(1))
        bundle.session(entry(first, "hola"), translating: true)                   // part 2 pending
        await mainQueueHop()
        #expect(bundle.clock.pendingDeadlines == [.seconds(30)])

        bundle.session(entry(first, "hola, amigo"))
        await bundle.waitDeadlines([.milliseconds(2500), .seconds(30)])
        bundle.session(entry(first, "hola, amigo"), speaking: true)               // flips back: reset
        await bundle.waitDeadlines([.seconds(30)])
        bundle.session(entry(first, "hola, amigo"))
        await bundle.waitDeadlines([.milliseconds(2500), .seconds(30)])
        bundle.clock.advance(by: .milliseconds(1400))
        await mainQueueHop()
        #expect(bundle.rehearsal.state.isRunning)
        bundle.clock.advance(by: .milliseconds(100))

        await bundle.finish()
        #expect(bundle.rehearsal.state == .passed(said: "hello my friend", received: "hola, amigo"))
    }

    @Test("a second sentence never replaces the first")
    func ignoresSecondSentence() async {
        let bundle = makeRehearsal()
        await bundle.begin()
        await bundle.capture()
        bundle.hearTranslation()

        let first = entry("hello")
        bundle.session(first, translating: true)
        await bundle.waitState(.translating(said: "hello"))
        bundle.session(entry("second sentence", "segunda frase"))
        await mainQueueHop()
        #expect(bundle.rehearsal.state == .translating(said: "hello"))
        #expect(bundle.clock.pendingDeadlines == [.seconds(30)])

        bundle.session(entry(first, "hola"))
        await bundle.waitDeadlines([.milliseconds(1500), .seconds(30)])
        bundle.clock.advance(by: .milliseconds(1500))

        await bundle.finish()
        #expect(bundle.rehearsal.state == .passed(said: "hello", received: "hola"))
    }

    @Test("no transcript 15 s after capture fails not heard")
    func notHeardAfter15s() async {
        let bundle = makeRehearsal()
        await bundle.begin()
        await bundle.capture()

        bundle.clock.advance(by: .seconds(15))

        await bundle.finish()
        #expect(bundle.rehearsal.state == .failed(.notHeard))
        #expect(bundle.host.stopCount == 1)
        #expect(bundle.listener.stopCount == 1)
    }

    @Test("a delivered sentence BlackHole never heard fails not received")
    func notReceivedWhenListenerSilent() async {
        let bundle = makeRehearsal()
        await bundle.begin()
        await bundle.capture()
        bundle.listener.yield(-100, milliseconds: 500)

        bundle.session(entry("hello", "hola"))
        await bundle.waitDeadlines([.milliseconds(1500), .seconds(30)])
        bundle.clock.advance(by: .milliseconds(1500))

        await bundle.finish()
        #expect(bundle.rehearsal.state == .failed(.notReceived))
        #expect(bundle.host.stopCount == 1)
    }

    @Test("no complete delivery 30 s after capture fails not received")
    func notReceivedAfter30s() async {
        let bundle = makeRehearsal()
        await bundle.begin()
        await bundle.capture()
        bundle.session(entry("hello"), translating: true)
        await bundle.waitDeadlines([.seconds(30)])

        bundle.clock.advance(by: .seconds(30))

        await bundle.finish()
        #expect(bundle.rehearsal.state == .failed(.notReceived))
    }

    @Test("Preparing… is capped at 90 s")
    func preparingTimesOut() async {
        let bundle = makeRehearsal()
        await bundle.begin()

        bundle.clock.advance(by: .seconds(90))

        await bundle.finish()
        #expect(bundle.rehearsal.state == .failed(.preparingTooLong))
        #expect(bundle.host.stopCount == 1)
        #expect(bundle.listener.stopCount == 1)
    }

    @Test("a pipeline error fails the rehearsal with its message")
    func pipelineErrorFails() async {
        let bundle = makeRehearsal()
        await bundle.begin()
        await bundle.capture()

        bundle.host.snapshot = RehearsalSnapshot(isCapturing: true, isActive: true, error: "boom")

        await bundle.finish()
        #expect(bundle.rehearsal.state == .failed(.pipeline("boom")))
        #expect(bundle.host.stopCount == 1)
    }

    @Test("cancel mid-rehearsal stops the session and the listener once, back to ready")
    func cancelMidRehearsalStops() async {
        let bundle = makeRehearsal()
        await bundle.begin()
        await bundle.capture()
        bundle.session(entry("hello"), translating: true)
        await bundle.waitState(.translating(said: "hello"))

        await bundle.boundedCancel()

        #expect(bundle.rehearsal.state == .ready)
        #expect(bundle.host.stopCount == 1)
        #expect(bundle.listener.stopCount == 1)
        #expect(await waitUntil(timeout: settle) { bundle.clock.sleeperCount == 0 })
        await bundle.boundedCancel()   // a second cancel is a no-op
        #expect(bundle.host.stopCount == 1)
        #expect(bundle.listener.stopCount == 1)
    }

    @Test("cancel keeps the last result; a cancelled new run goes back to it; playback stops")
    func cancelKeepsResult() async {
        let player = FakeRecordingPlayer()
        let bundle = makeRehearsal(player: player)
        await bundle.begin()
        bundle.clock.advance(by: .seconds(90))
        await bundle.finish()
        #expect(bundle.rehearsal.state == .failed(.preparingTooLong))
        #expect(player.stopCount == 1)   // a run stops the previous playback first

        await bundle.boundedCancel()   // leaving the step
        #expect(bundle.rehearsal.state == .failed(.preparingTooLong))
        #expect(player.stopCount == 2)

        bundle.rehearsal.rehearse()
        #expect(await waitUntil(timeout: settle) { bundle.host.startCount == 2 && bundle.clock.sleeperCount == 1 })
        #expect(player.stopCount == 3)
        await bundle.boundedCancel()
        #expect(bundle.rehearsal.state == .failed(.preparingTooLong))
        #expect(bundle.host.stopCount == 2)
        #expect(player.stopCount == 4)
    }

    @Test("the session and listener are released on every failure, even before capture")
    func stopAlwaysCalledOnFailure() async {
        let bundle = makeRehearsal()
        await bundle.begin()

        bundle.host.snapshot = RehearsalSnapshot(error: "packs missing")

        await bundle.finish()
        #expect(bundle.rehearsal.state == .failed(.pipeline("packs missing")))
        #expect(bundle.host.stopCount == 1)
        #expect(bundle.listener.stopCount == 1)
        #expect(await waitUntil(timeout: settle) { bundle.clock.sleeperCount == 0 })
    }

    @Test("the 15 s budget starts when capture runs, not at Rehearse")
    func timersStartAtCapture() async {
        let bundle = makeRehearsal()
        await bundle.begin()
        bundle.clock.advance(by: .seconds(14))
        await mainQueueHop()
        #expect(bundle.rehearsal.state == .preparing)

        await bundle.capture()   // deadlines at 29 s and 44 s
        bundle.clock.advance(by: .seconds(14))
        await mainQueueHop()
        #expect(bundle.rehearsal.state == .listening)
        bundle.clock.advance(by: .seconds(1))

        await bundle.finish()
        #expect(bundle.rehearsal.state == .failed(.notHeard))
    }

    @Test("an unavailable reason hides the last result until it clears")
    func refreshKeepsResult() async {
        let bundle = makeRehearsal()
        bundle.rehearsal.refresh(availability: "Install BlackHole 2ch in step 2")
        #expect(bundle.rehearsal.state == .unavailable("Install BlackHole 2ch in step 2"))
        bundle.rehearsal.rehearse()
        #expect(bundle.host.startCount == 0)

        bundle.rehearsal.refresh(availability: nil)
        #expect(bundle.rehearsal.state == .ready)
        await bundle.begin()
        bundle.clock.advance(by: .seconds(90))
        await bundle.finish()
        bundle.rehearsal.refresh(availability: "Available when no call is running")
        bundle.rehearsal.refresh(availability: nil)
        #expect(bundle.rehearsal.state == .failed(.preparingTooLong))
    }
}

private func entry(_ base: TranscriptEntry, _ translation: String) -> TranscriptEntry {
    var copy = base
    copy.translation = translation
    return copy
}
