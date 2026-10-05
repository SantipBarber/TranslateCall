import AVFoundation
import Testing
@testable import TranslateCall

@Suite("TTSPlaybackService")
struct TTSPlaybackServiceTests {

    @Test("utterances run one at a time, in FIFO order (REQ-T-11)")
    func fifoOneAtATime() async {
        let harness = TTSPlaybackHarness()
        for text in ["one", "two", "three"] { await harness.service.speak(text: text, locale: english) }
        for played in 1...3 {
            #expect(await waitUntil { harness.output.scheduledCount == played })
            #expect(harness.primary.texts.count == played, "the next utterance started before this one was heard")
            harness.output.completeAll()
        }
        #expect(harness.primary.texts == ["one", "two", "three"])
        await harness.service.deactivate()
    }

    @Test("blank text is ignored (REQ-T-12)")
    func blankIgnored() async {
        let harness = TTSPlaybackHarness(output: FakeOutput(autoComplete: true))
        await harness.service.speak(text: "   ", locale: english)
        await harness.service.speak(text: "\n\t", locale: english)
        await harness.service.speak(text: "real", locale: english)
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(harness.primary.texts == ["real"])
        await harness.service.deactivate()
    }

    @Test("buffers are scheduled as they arrive and only the last one is awaited (REQ-T-13)")
    func schedulesAheadAwaitsLast() async {
        let script = FakeSynthesizer.Script(buffers: (0..<3).map { _ in makePCMBuffer(frames: 1_600, fill: 0.5) })
        let harness = TTSPlaybackHarness(primary: FakeSynthesizer(scripts: [script]))
        await harness.service.speak(text: "three buffers", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 3 }, "later buffers waited for earlier ones")
        harness.output.complete(index: 2)
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        await harness.service.deactivate()
    }

    @Test("isSpeaking: true while the queue plays, false after the last buffer, no flicker in between (REQ-T-14)")
    func truthfulSpeaking() async {
        let harness = TTSPlaybackHarness()
        await harness.service.speak(text: "first", locale: english)
        await harness.service.speak(text: "second", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 && harness.speaking.values == [true] })
        harness.output.completeAll()
        #expect(await waitUntil { harness.output.scheduledCount == 2 })
        #expect(harness.speaking.values == [true])
        harness.output.completeAll()
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        await harness.service.deactivate()
    }

    @Test("stopSpeaking: isSpeaking false at once, queue cleared, playback stopped (REQ-T-14/15)")
    func stopIsImmediate() async {
        let harness = TTSPlaybackHarness()
        await harness.service.speak(text: "playing", locale: english)
        await harness.service.speak(text: "queued", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })

        await harness.service.stopSpeaking()

        #expect(harness.output.stopCount == 1)
        #expect(await harness.service.pendingCount == 0)
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(harness.primary.texts == ["playing"])
        #expect(harness.events.values.isEmpty)
        await harness.service.deactivate()
    }

    @Test("stop during synthesis, then a new sentence: only the new one is ever scheduled (REQ-T-15, A9, A3e)")
    func stopDuringSynthesis() async {
        let stale = makePCMBuffer(frames: 1_600, fill: 0.9)
        let fresh = makePCMBuffer(frames: 1_600, fill: 0.1)
        let primary = FakeSynthesizer(scripts: [
            FakeSynthesizer.Script(buffers: [makePCMBuffer(frames: 1_600, fill: 0.5), stale], holdBefore: 1),
            FakeSynthesizer.Script(buffers: [fresh])
        ])
        let harness = TTSPlaybackHarness(primary: primary, output: FakeOutput(autoComplete: true))
        await harness.service.speak(text: "old", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 && primary.gate.waiterCount == 1 })

        await harness.service.stopSpeaking()
        await harness.service.speak(text: "new", locale: english)
        primary.gate.open()                       // the old producer now yields `stale`

        #expect(await waitUntil { harness.output.scheduledCount == 2 })
        #expect(harness.output.scheduled.last === fresh)
        #expect(!harness.output.scheduled.contains { $0 === stale })
        #expect(await waitUntil { primary.cancelledCount == 1 })
        await harness.service.deactivate()
    }

    @Test("the watchdog skips a synthesizer that never finishes and isSpeaking returns to false (REQ-T-16)")
    func watchdog() async {
        let primary = FakeSynthesizer(scripts: [FakeSynthesizer.Script(buffers: [], hang: true)])
        let harness = TTSPlaybackHarness(primary: primary)
        await harness.service.speak(text: "hangs", locale: english)
        #expect(await waitUntil { harness.clock.pendingDeadlines == [.seconds(30)] })

        harness.clock.advance(by: .seconds(30))

        #expect(await waitUntil { harness.events.values == [.utteranceSkipped(.timeout)] })
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(await waitUntil { primary.cancelledCount == 1 })
        await harness.service.deactivate()
    }

    @Test("Review focus: a long utterance is not cut by the watchdog once its synthesis is done (M3)")
    func watchdogSparesLongPlayback() async {
        let forty = makePCMBuffer(frames: 640_000, sampleRate: 16_000, fill: 0.5)   // 40 s of audio
        let harness = TTSPlaybackHarness(primary: FakeSynthesizer(scripts: [FakeSynthesizer.Script(buffers: [forty])]))
        await harness.service.speak(text: "long", locale: english)
        #expect(await waitUntil { harness.clock.pendingDeadlines == [.seconds(45)] })   // 40 s + 5 s grace

        harness.clock.advance(by: .seconds(31))                                        // past the watchdog
        harness.output.completeAll()

        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(harness.events.values.isEmpty)
        await harness.service.deactivate()
    }

    @Test("Review focus: an output that never reports playback ends the utterance as outputUnavailable")
    func stalledOutput() async {
        let oneSecond = makePCMBuffer(frames: 16_000, sampleRate: 16_000, fill: 0.5)
        let script = FakeSynthesizer.Script(buffers: [oneSecond])
        let harness = TTSPlaybackHarness(primary: FakeSynthesizer(scripts: [script]))
        await harness.service.speak(text: "device vanished", locale: english)
        #expect(await waitUntil { harness.clock.pendingDeadlines == [.seconds(6)] })    // 1 s + 5 s grace

        harness.clock.advance(by: .seconds(6))

        #expect(await waitUntil { harness.events.values == [.utteranceSkipped(.outputUnavailable)] })
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(harness.output.stopCount >= 1)
        await harness.service.deactivate()
    }

    @Test("a buffer the output refuses skips the utterance as outputUnavailable; the next one is tried")
    func scheduleFailure() async {
        let output = FakeOutput(autoComplete: true)
        output.failSchedules(with: FakeSynthError.boom)
        let harness = TTSPlaybackHarness(output: output)
        await harness.service.speak(text: "refused", locale: english)
        #expect(await waitUntil { harness.events.values == [.utteranceSkipped(.outputUnavailable)] })

        output.failSchedules(with: nil)
        await harness.service.speak(text: "accepted", locale: english)

        #expect(await waitUntil { output.scheduledCount == 1 })
        #expect(await waitUntil { harness.speaking.values == [true, false, true, false] })
        await harness.service.deactivate()
    }

    @Test("every scheduled buffer reaches the monitor (REQ-T-17)")
    func observerSeesEveryBuffer() async {
        let script = FakeSynthesizer.Script(buffers: (0..<3).map { _ in makePCMBuffer() })
        let harness = TTSPlaybackHarness(primary: FakeSynthesizer(scripts: [script]),
                                         output: FakeOutput(autoComplete: true))
        let seen = LockedArray<AVAudioPCMBuffer>()
        await harness.service.setBufferObserver { seen.append($0) }

        await harness.service.speak(text: "three", locale: english)

        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(seen.values.count == 3)
        #expect(zip(seen.values, harness.output.scheduled).allSatisfy { $0 === $1 })
        #expect(zip(harness.output.scheduled, script.buffers).allSatisfy { $0 === $1 }, "buffers out of order")
        await harness.service.deactivate()
    }

    @Test("one metrics record per heard utterance: engine used, text length, locale (REQ-T-19)")
    func metrics() async {
        let harness = TTSPlaybackHarness(primary: FakeSynthesizer(engine: .kokoro), output: FakeOutput(autoComplete: true))
        await harness.service.speak(text: "hello", locale: english)
        #expect(await waitUntil { await harness.metrics.recent.count == 1 })
        let record = await harness.metrics.recent[0]
        #expect(record.engine == .kokoro)
        #expect(record.textLength == 5)
        #expect(record.locale == english)
        #expect(record.synthesisLatencyMs >= 0)
        await harness.service.deactivate()
    }

    @Test("no voice for the locale: skipped with .noVoice, nothing synthesized, isSpeaking untouched")
    func noVoice() async {
        let harness = TTSPlaybackHarness(primary: FakeSynthesizer(canSpeak: { _ in false }))
        await harness.service.speak(text: "unspeakable", locale: Locale(identifier: "xx-XX"))
        #expect(await waitUntil { harness.events.values == [.utteranceSkipped(.noVoice)] })
        #expect(harness.primary.texts.isEmpty)
        #expect(harness.speaking.values.isEmpty)
        await harness.service.deactivate()
    }

    @Test("the primary fails and there is no fallback: skipped with .primaryFailed (REQ-T-20)")
    func primaryFailedWithoutFallback() async {
        let harness = TTSPlaybackHarness(primary: FakeSynthesizer(scripts: [FakeSynthesizer.Script(failAfter: 0)]))
        await harness.service.speak(text: "fails", locale: english)
        let expected = TTSEvent.utteranceSkipped(.primaryFailed(FakeSynthError.boom.localizedDescription))
        #expect(await waitUntil { harness.events.values == [expected] })
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        await harness.service.deactivate()
    }

    @Test("deactivate shuts output and synthesizer down, finishes both streams and ignores later speech")
    func deactivate() async {
        let harness = TTSPlaybackHarness()
        await harness.service.deactivate()
        #expect(harness.output.shutdownCount == 1)
        #expect(harness.primary.shutdownCount == 1)
        #expect(await waitUntil { harness.speaking.isFinished && harness.events.isFinished })
        await harness.service.speak(text: "too late", locale: english)
        #expect(harness.primary.texts.isEmpty)
        #expect(await harness.service.pendingCount == 0)
    }
}
