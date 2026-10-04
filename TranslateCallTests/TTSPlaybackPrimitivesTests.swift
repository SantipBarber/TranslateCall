import AVFoundation
import Testing
@testable import TranslateCall

@Suite("PlaybackHandle")
struct PlaybackHandleTests {
    @Test("wait returns once the buffer has played back, whether marked before or after the wait")
    func playedResumesWaiters() async throws {
        let early = PlaybackHandle()
        early.markPlayed()
        try await early.wait()

        let late = PlaybackHandle()
        let waiter = Task { try await late.wait() }
        late.markPlayed()
        try await waiter.value
        #expect(late.isPlayed)
    }

    @Test("a cancelled handle throws CancellationError to its waiters; the first resolution wins")
    func cancelThrowsAndFirstWins() async {
        let handle = PlaybackHandle()
        handle.markCancelled()
        handle.markPlayed()
        #expect(!handle.isPlayed)
        await #expect(throws: CancellationError.self) { try await handle.wait() }
    }

    @Test("cancelling the waiting task ends the wait but leaves the handle unresolved")
    func waiterCancellation() async {
        let handle = PlaybackHandle()
        let waiter = Task { try await handle.wait() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(!handle.isResolved)
    }
}

@Suite("TestClock")
struct TestClockTests {
    @Test("a sleeper resumes only when time reaches its deadline")
    func advanceResumesDueSleepers() async throws {
        let clock = TestClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(5)) }
        #expect(await waitUntil { clock.sleeperCount == 1 })
        #expect(clock.pendingDeadlines == [.seconds(5)])
        clock.advance(by: .seconds(4))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(1))
        try await sleeper.value
        #expect(clock.sleeperCount == 0)
    }

    @Test("cancelling a sleeper throws CancellationError and unregisters it")
    func cancellation() async {
        let clock = TestClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(5)) }
        #expect(await waitUntil { clock.sleeperCount == 1 })
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test("a deadline already reached does not suspend")
    func pastDeadline() async throws {
        let clock = TestClock()
        clock.advance(by: .seconds(10))
        try await clock.sleep(until: clock.now.advanced(by: .seconds(-1)), tolerance: nil)
    }
}

@Suite("Utterance helpers")
struct UtteranceHelpersTests {
    @Test("truncation keeps text up to the limit and cuts at the last word boundary (REQ-T-04)")
    func truncation() {
        let long = String(repeating: "hello ", count: 92)            // 552 characters
        let cut = UtteranceText.truncated(long, limit: 500)
        #expect(cut.count <= 500)
        #expect(!cut.hasSuffix(" "))
        #expect(long.hasPrefix(cut))
        let exact = String(repeating: "a", count: 500)
        #expect(UtteranceText.truncated(exact, limit: 500) == exact)
        #expect(UtteranceText.truncated(String(repeating: "a", count: 600), limit: 500).count == 500)
    }

    @Test("mono buffers carry the samples at the given rate; empty samples give nil")
    func monoBuffers() throws {
        let buffer = try #require(PCMBufferFactory.mono([0.1, 0.2, 0.3], sampleRate: 24_000))
        #expect(buffer.format.sampleRate == 24_000)
        #expect(buffer.format.channelCount == 1)
        #expect(buffer.frameLength == 3)
        #expect(buffer.floatChannelData?[0][2] == 0.3)
        #expect(PCMBufferFactory.mono([], sampleRate: 24_000) == nil)
    }

    @Test("events compare by case and payload")
    func eventEquality() {
        #expect(TTSEvent.fellBack(from: .edgeTTS, to: .avSpeech) == .fellBack(from: .edgeTTS, to: .avSpeech))
        #expect(TTSEvent.utteranceSkipped(.primaryFailed("a")) != .utteranceSkipped(.primaryFailed("b")))
    }
}
