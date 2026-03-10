import Testing
import Combine
@testable import TranslateCall

// Using a short delay so tests don't wait 300ms each.
private let testDelay: Duration = .milliseconds(50)
private let waitAfterDelay: UInt64 = 100_000_000  // 100ms in nanoseconds

@Suite("HalfDuplexManager", .serialized)
@MainActor
struct HalfDuplexManagerTests {

    // MARK: - T1: Initial state

    @Test("Initial state is .listening")
    func initialStateIsListening() {
        let mock = MockHalfDuplexCoordinator()
        let manager = HalfDuplexManager(coordinator: mock, transitionDelay: testDelay)
        #expect(manager.state == .listening)
    }

    // MARK: - T2: Incoming TTS → .speaking

    @Test("Incoming TTS transitions to .speaking")
    func incomingSpeakingTransitionsToSpeaking() {
        let mock = MockHalfDuplexCoordinator()
        let manager = HalfDuplexManager(coordinator: mock, transitionDelay: testDelay)
        mock.isIncomingSpeaking = true
        #expect(manager.state == .speaking)
    }

    // MARK: - T3: Outgoing TTS → .speaking

    @Test("Outgoing TTS transitions to .speaking")
    func outgoingSpeakingTransitionsToSpeaking() {
        let mock = MockHalfDuplexCoordinator()
        let manager = HalfDuplexManager(coordinator: mock, transitionDelay: testDelay)
        mock.isOutgoingSpeaking = true
        #expect(manager.state == .speaking)
    }

    // MARK: - T4: Incoming TTS mutes mic (suppresses outgoing capture)

    @Test("Incoming TTS mutes outgoing capture")
    func incomingSpeakingMutesOutgoingCapture() {
        let mock = MockHalfDuplexCoordinator()
        let manager = HalfDuplexManager(coordinator: mock, transitionDelay: testDelay)
        mock.isIncomingSpeaking = true
        // suppressOutgoingCapture(true) should have been called
        #expect(mock.suppressOutgoingCaptureCalls.last == true)
        withExtendedLifetime(manager) {}  // keep alive through assertions
    }

    // MARK: - T5: Outgoing TTS blocks loopback (suppresses incoming pipeline)

    @Test("Outgoing TTS blocks incoming loopback")
    func outgoingSpeakingBlocksIncomingPipeline() {
        let mock = MockHalfDuplexCoordinator()
        let manager = HalfDuplexManager(coordinator: mock, transitionDelay: testDelay)
        mock.isOutgoingSpeaking = true
        // suppressIncomingPipeline(true) should have been called
        #expect(mock.suppressIncomingPipelineCalls.last == true)
        withExtendedLifetime(manager) {}
    }

    // MARK: - T6: Both stop → .listening after delay

    @Test("Both TTS stopped transitions to .listening after delay")
    func bothStopTransitionsToListeningAfterDelay() async throws {
        let mock = MockHalfDuplexCoordinator()
        let manager = HalfDuplexManager(coordinator: mock, transitionDelay: testDelay)

        // Start speaking
        mock.isIncomingSpeaking = true
        #expect(manager.state == .speaking)

        // Stop speaking → should enter .transitioning
        mock.isIncomingSpeaking = false
        #expect(manager.state == .transitioning)

        // Wait for buffer to elapse (testDelay=50ms + margin)
        try await Task.sleep(nanoseconds: waitAfterDelay)
        #expect(manager.state == .listening)
    }

    // MARK: - T7: New TTS during transition cancels buffer

    @Test("New TTS during .transitioning cancels buffer and returns to .speaking")
    func newTTSDuringTransitionCancelsBuffer() async throws {
        let mock = MockHalfDuplexCoordinator()
        let manager = HalfDuplexManager(coordinator: mock, transitionDelay: testDelay)

        // Start → stop → transitioning
        mock.isIncomingSpeaking = true
        mock.isIncomingSpeaking = false
        #expect(manager.state == .transitioning)

        // New speaking event while transitioning — should cancel buffer
        mock.isOutgoingSpeaking = true
        #expect(manager.state == .speaking)

        // Wait past the original delay — should NOT become .listening because TTS is still active
        try await Task.sleep(nanoseconds: waitAfterDelay)
        #expect(manager.state == .speaking)
    }

    // MARK: - T8: Deactivate lifts suppression

    @Test("Deactivate lifts all suppression and resets to .listening")
    func deactivateLiftsSuppression() {
        let mock = MockHalfDuplexCoordinator()
        let manager = HalfDuplexManager(coordinator: mock, transitionDelay: testDelay)

        // Activate speaking (incoming) — mic is suppressed
        mock.isIncomingSpeaking = true
        #expect(manager.state == .speaking)
        #expect(mock.suppressOutgoingCaptureCalls.last == true)

        // Deactivate — should lift suppression and reset state
        manager.deactivate()
        #expect(manager.state == .listening)
        #expect(mock.suppressOutgoingCaptureCalls.last == false)
        #expect(mock.suppressIncomingPipelineCalls.last == false)
    }

    // MARK: - T9: Only-outgoing suppresses only incoming pipeline (not mic)

    @Test("Only outgoing TTS: incoming pipeline suppressed, mic not suppressed")
    func onlyOutgoingSpeakingSuppressesOnlyIncomingPipeline() {
        let mock = MockHalfDuplexCoordinator()
        let manager = HalfDuplexManager(coordinator: mock, transitionDelay: testDelay)

        mock.isOutgoingSpeaking = true

        // Outgoing TTS → suppress incoming (loopback), but NOT outgoing capture (mic)
        #expect(mock.suppressIncomingPipelineCalls.last == true)
        #expect(mock.suppressOutgoingCaptureCalls.last == false)
        withExtendedLifetime(manager) {}
    }
}
