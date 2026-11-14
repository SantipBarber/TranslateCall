import AVFoundation
import Testing
@testable import TranslateCall

/// FR-CS.5 (design §7a): the next utterance synthesizes while the current one plays, one ahead at most.
@Suite("TTSPlaybackService look-ahead (FR-CS.5)")
struct TTSPlaybackLookAheadTests {

    private func limits(coalescing: Bool = false, grace: Duration = .seconds(5)) -> TTSPlaybackLimits {
        var limits = coalescing ? TTSPlaybackLimits.default : .uncoalesced
        limits.playbackGrace = grace
        return limits
    }

    /// "a" playing (its handle not completed) and "b" synthesized ahead of it.
    private func playingWithOneAhead(_ harness: TTSPlaybackHarness) async {
        await harness.service.speak(text: "a", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        await harness.service.speak(text: "b", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 2 })
    }

    @Test("the next utterance synthesizes while the current one plays (REQ-CS-50)")
    func nextSynthesizesWhileCurrentPlays() async {
        let harness = TTSPlaybackHarness(output: FakeOutput(autoComplete: false))
        await harness.service.speak(text: "a", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        await harness.service.speak(text: "b", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 2 }, "b waited for a to be heard")
        #expect(harness.primary.texts == ["a", "b"])
        harness.output.completeAll()
        await harness.service.deactivate()
    }

    @Test("at most one utterance ahead; later sentences wait and are coalesced (REQ-CS-51)")
    func atMostOneAhead() async {
        let harness = TTSPlaybackHarness(output: FakeOutput(autoComplete: false), limits: limits(coalescing: true))
        await playingWithOneAhead(harness)
        await harness.service.speak(text: "c", locale: english)
        await harness.service.speak(text: "d", locale: english)
        await mainQueueHop()
        #expect(await harness.service.pendingCount == 2)
        #expect(harness.primary.texts == ["a", "b"])

        harness.output.complete(index: 0)

        #expect(await waitUntil { harness.output.scheduledCount == 3 })
        #expect(harness.primary.texts == ["a", "b", "c d"])
        harness.output.completeAll()
        await harness.service.deactivate()
    }

    @Test("stopSpeaking drops the playing utterance and the one ahead, at once, with no skip (REQ-CS-53)")
    func stopDropsPlayingAndAhead() async {
        let harness = TTSPlaybackHarness(output: FakeOutput(autoComplete: false))
        await playingWithOneAhead(harness)

        await harness.service.stopSpeaking()

        #expect(await waitUntil { harness.speaking.values.last == false })
        #expect(harness.output.stopCount == 1)
        await harness.service.speak(text: "e", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 3 })
        #expect(harness.primary.texts == ["a", "b", "e"])
        #expect(!harness.events.values.contains { if case .utteranceSkipped = $0 { true } else { false } })
        harness.output.complete(index: 2)
        #expect(await waitUntil { harness.speaking.values == [true, false, true, false] })
        #expect(!harness.events.values.contains { if case .utteranceSkipped = $0 { true } else { false } })
        await harness.service.deactivate()
    }

    @Test("an output stall while one plays skips the one ahead too (REQ-CS-54)")
    func stallSkipsAheadToo() async {
        let harness = TTSPlaybackHarness(output: FakeOutput(autoComplete: false), limits: limits(grace: .seconds(1)))
        await playingWithOneAhead(harness)
        // Only a's playback bound is left (b's watchdog is gone): b's synthesis has ended.
        #expect(await waitUntil { harness.clock.pendingDeadlines.count == 1 })

        harness.clock.advance(by: .seconds(2))

        let skipped = TTSEvent.utteranceSkipped(.outputUnavailable)
        #expect(await waitUntil { harness.events.values == [skipped, skipped] })
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(harness.output.stopCount == 1)
        await harness.service.deactivate()
    }

    @Test("the utterance ahead still synthesizing is cancelled when the output stalls and schedules nothing (REQ-CS-54)")
    func aheadStillSynthesizingStopsScheduling() async {
        let two = FakeSynthesizer.Script(buffers: [makePCMBuffer(frames: 1_600, fill: 0.5),
                                                   makePCMBuffer(frames: 1_600, fill: 0.5)], holdBefore: 1)
        let primary = FakeSynthesizer(scripts: [FakeSynthesizer.Script(), two])
        let harness = TTSPlaybackHarness(primary: primary, output: FakeOutput(autoComplete: false),
                                         limits: limits(grace: .seconds(1)))
        await playingWithOneAhead(harness)
        #expect(await waitUntil { primary.gate.waiterCount == 1 })

        harness.clock.advance(by: .seconds(2))                       // a stalls; b's watchdog is at 30 s

        // b's attempt is cancelled at once (its synthesizer released), without waiting for its next buffer.
        let skipped = TTSEvent.utteranceSkipped(.outputUnavailable)
        #expect(await waitUntil { harness.events.values == [skipped, skipped] })
        #expect(primary.cancelledCount == 1)
        #expect(primary.gate.waiterCount == 1, "b's next buffer was never released")
        primary.gate.open()
        await mainQueueHop()
        #expect(harness.output.scheduledCount == 2)
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        await harness.service.deactivate()
    }

    @Test("the utterance ahead falls back while the current one keeps playing (REQ-CS-52)")
    func fallbackOnAheadWhileCurrentPlays() async {
        let primary = FakeSynthesizer(engine: .edgeTTS, scripts: [FakeSynthesizer.Script(),
                                                                  FakeSynthesizer.Script(buffers: [], failAfter: 0)])
        let fallback = FakeSynthesizer(engine: .avSpeech)
        let harness = TTSPlaybackHarness(primary: primary, fallback: fallback, output: FakeOutput(autoComplete: false))
        await harness.service.speak(text: "a", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        await harness.service.speak(text: "b", locale: english)

        #expect(await waitUntil { fallback.texts == ["b"] && harness.output.scheduledCount == 2 })
        #expect(await waitUntil { harness.events.values == [.fellBack(from: .edgeTTS, to: .avSpeech)] })
        harness.output.completeAll()
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(await waitUntil { await harness.metrics.recent.map(\.engine) == [.edgeTTS, .avSpeech] })
        await harness.service.deactivate()
    }

    @Test("isSpeaking stays true across the handoff to the utterance ahead (REQ-CS-55)")
    func speakingStaysTrueAcrossHandoff() async {
        let harness = TTSPlaybackHarness(output: FakeOutput(autoComplete: false))
        await playingWithOneAhead(harness)

        harness.output.complete(index: 0)
        #expect(await waitUntil { await harness.metrics.recent.count == 1 })   // a's drain has ended
        await mainQueueHop()
        #expect(harness.speaking.values == [true])

        harness.output.complete(index: 1)
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        await harness.service.deactivate()
    }

    @Test("handoff gap is zero when the next audio is scheduled before the current one ends (REQ-CS-56)")
    func handoffGapZeroWhenInTime() async {
        let clock = PipelineTracerTests.ManualNow()
        let harness = TTSPlaybackHarness(output: FakeOutput(autoComplete: false), now: { clock.now })
        await harness.service.speak(text: "a", locale: english)                // 0.1 s of audio at t = 0
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        #expect(harness.output.handoffGaps.isEmpty, "the first utterance follows no audio")

        clock.advance(.milliseconds(50))
        await harness.service.speak(text: "b", locale: english)

        #expect(await waitUntil { harness.output.scheduledCount == 2 })
        #expect(harness.output.handoffGaps == [.zero])
        harness.output.completeAll()
        await harness.service.deactivate()
    }

    @Test("handoff gap is the silence between the audio scheduled and the next first buffer (REQ-CS-56)")
    func handoffGapWhenLate() async {
        let clock = PipelineTracerTests.ManualNow()
        let harness = TTSPlaybackHarness(output: FakeOutput(autoComplete: false), now: { clock.now })
        await harness.service.speak(text: "a", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        #expect(harness.output.handoffGaps.isEmpty)

        clock.advance(.milliseconds(300))
        await harness.service.speak(text: "b", locale: english)

        #expect(await waitUntil { harness.output.scheduledCount == 2 })
        #expect(harness.output.handoffGaps == [.milliseconds(200)])
        harness.output.completeAll()
        await harness.service.deactivate()
    }

    @Test("stopSpeaking forgets the audio timeline: the next utterance reports no gap")
    func stopResetsHandoff() async {
        let harness = TTSPlaybackHarness(output: FakeOutput(autoComplete: false))
        await harness.service.speak(text: "a", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        await harness.service.stopSpeaking()
        await harness.service.speak(text: "b", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 2 })
        #expect(harness.output.handoffGaps.isEmpty)
        harness.output.completeAll()
        await harness.service.deactivate()
    }

    @Test("outcomes are reported in utterance order: a's skip before b's")
    func outcomesInOrder() async {
        let primary = FakeSynthesizer(scripts: [FakeSynthesizer.Script(failAfter: 1),
                                                FakeSynthesizer.Script(buffers: [], failAfter: 0)])
        let harness = TTSPlaybackHarness(primary: primary, output: FakeOutput(autoComplete: false))
        await harness.service.speak(text: "a", locale: english)                // interrupted after its audio
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        await harness.service.speak(text: "b", locale: english)                // fails with no audio, no fallback
        #expect(await waitUntil { primary.texts == ["a", "b"] })
        await mainQueueHop()
        #expect(harness.events.values.isEmpty, "b's skip came before a was heard")

        harness.output.completeAll()

        let failed = TTSEvent.utteranceSkipped(.primaryFailed(FakeSynthError.boom.localizedDescription))
        #expect(await waitUntil { harness.events.values == [.utteranceSkipped(.interrupted), failed] })
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        await harness.service.deactivate()
    }
}
