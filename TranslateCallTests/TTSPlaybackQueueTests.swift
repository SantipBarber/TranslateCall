import AVFoundation
import Testing
@testable import TranslateCall

private let spanish = Locale(identifier: "es-ES")

private func limits(backlogAt threshold: Int = 20, coalesceUpTo characters: Int = 400) -> TTSPlaybackLimits {
    var limits = TTSPlaybackLimits.default
    limits.backlogNoticeThreshold = threshold
    limits.maxCoalescedCharacters = characters
    return limits
}

@Suite("TTSPlaybackService queue (F8.5.3)")
struct TTSPlaybackQueueTests {

    @Test("nothing is dropped: 25 sentences behind a busy one are all spoken, in order (REQ-Q-01)")
    func neverDropsPastOldCap() async {
        let harness = TTSPlaybackHarness(limits: limits())
        await harness.service.speak(text: "in flight", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })   // waits for playback
        let sentences = (1...25).map { "s\($0)" }
        for text in sentences { await harness.service.speak(text: text, locale: english) }

        harness.output.completeAll()
        #expect(await waitUntil { harness.output.scheduledCount == 2 })
        harness.output.completeAll()
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(harness.primary.texts == ["in flight", sentences.joined(separator: " ")])
        await harness.service.deactivate()
    }

    @Test("sentences that queued up meanwhile are spoken as one utterance (REQ-Q-02)")
    func coalescesPendingSameLocale() async {
        let harness = TTSPlaybackHarness(limits: limits())
        await harness.service.speak(text: "uno", locale: spanish)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        await harness.service.speak(text: "dos", locale: spanish)
        await harness.service.speak(text: "tres", locale: spanish)

        harness.output.completeAll()
        #expect(await waitUntil { harness.output.scheduledCount == 2 })
        #expect(harness.primary.texts == ["uno", "dos tres"])
        harness.output.completeAll()
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        await harness.service.deactivate()
    }

    @Test("Review focus: coalescing stops at the character limit; a longer sentence alone is spoken whole")
    func coalescingRespectsCharacterLimit() async {
        let harness = TTSPlaybackHarness(output: FakeOutput(autoComplete: false), limits: limits(coalesceUpTo: 10))
        let long = "a sentence much longer than ten characters"
        await harness.service.speak(text: "first", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        for text in ["aaaa", "bbbb", "cccc", long] { await harness.service.speak(text: text, locale: english) }

        for played in 2...4 {
            harness.output.completeAll()
            #expect(await waitUntil { harness.output.scheduledCount == played })
        }
        #expect(harness.primary.texts == ["first", "aaaa bbbb", "cccc", long])
        harness.output.completeAll()
        await harness.service.deactivate()
    }

    @Test("Review focus: sentences of another locale (language swapped mid-session) are never merged")
    func differentLocaleNotCoalesced() async {
        let harness = TTSPlaybackHarness(limits: limits())
        await harness.service.speak(text: "one", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        await harness.service.speak(text: "dos", locale: spanish)
        await harness.service.speak(text: "tres", locale: spanish)
        await harness.service.speak(text: "four", locale: english)

        for played in 2...3 {
            harness.output.completeAll()
            #expect(await waitUntil { harness.output.scheduledCount == played })
        }
        #expect(harness.primary.texts == ["one", "dos tres", "four"])
        harness.output.completeAll()
        await harness.service.deactivate()
    }

    @Test("a coalesced utterance falls back as one utterance (REQ-Q-04)")
    func coalescedFallsBackWhole() async {
        let primary = FakeSynthesizer(scripts: [FakeSynthesizer.Script(),
                                                FakeSynthesizer.Script(buffers: [], failAfter: 0)])
        let fallback = FakeSynthesizer(engine: .avSpeech)
        let harness = TTSPlaybackHarness(primary: primary, fallback: fallback, limits: limits())
        await harness.service.speak(text: "uno", locale: spanish)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        await harness.service.speak(text: "dos", locale: spanish)
        await harness.service.speak(text: "tres", locale: spanish)

        harness.output.completeAll()
        #expect(await waitUntil { harness.output.scheduledCount == 2 })
        #expect(fallback.texts == ["dos tres"])
        harness.output.completeAll()
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        await harness.service.deactivate()
    }

    @Test("the backlog notice fires once at the threshold and again only after the queue drained (REQ-Q-03)")
    func backlogNoticeOnceUntilDrained() async {
        let harness = TTSPlaybackHarness(limits: limits(backlogAt: 3, coalesceUpTo: 0))
        await harness.service.speak(text: "a", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 1 })
        for text in ["b", "c", "d"] { await harness.service.speak(text: text, locale: english) }
        #expect(await waitUntil { harness.events.values == [.backlog(pending: 3)] })
        await harness.service.speak(text: "e", locale: english)

        for played in 2...5 {
            harness.output.completeAll()
            #expect(await waitUntil { harness.output.scheduledCount == played })
        }
        harness.output.completeAll()
        #expect(await waitUntil { harness.speaking.values == [true, false] })
        #expect(harness.events.values == [.backlog(pending: 3)])

        await harness.service.speak(text: "f", locale: english)
        #expect(await waitUntil { harness.output.scheduledCount == 6 })
        for text in ["g", "h", "i"] { await harness.service.speak(text: text, locale: english) }
        #expect(await waitUntil { harness.events.values == [.backlog(pending: 3), .backlog(pending: 3)] })
        await harness.service.deactivate()
    }
}
