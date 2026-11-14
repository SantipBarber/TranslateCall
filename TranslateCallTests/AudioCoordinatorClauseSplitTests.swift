import Foundation
import Testing
@testable import TranslateCall

private let callTarget = CaptureTarget.app(bundleID: "com.test.call")

/// The split sentence and its two parts (ClauseSplitterTests).
private let sentenceText = "When we get to the station, we will call you from the taxi"
private let part0 = "When we get to the station,"
private let part1 = "we will call you from the taxi"
private let spoken0 = "TRANSLATED: \(part0)"
private let spoken1 = "TRANSLATED: \(part1)"
private let joined = "\(spoken0) \(spoken1)"

@MainActor
private func makeCoordinator(_ mocks: CoordinatorMocks, split: Bool = true) -> AudioCoordinator {
    let coordinator = AudioCoordinator(
        audioCapture: mocks.mockAudioCapture,
        systemCapture: mocks.mockSystemCapture,
        outgoingVADFactory: { mocks.mockVADFactory },
        incomingVADFactory: { mocks.mockIncomingVAD },
        outgoingSTTFactory: { _ in mocks.mockOutgoingSTT },
        incomingSTTFactory: { _ in mocks.mockIncomingSTT },
        outgoingTranslationService: mocks.mockOutgoingTranslation,
        incomingTranslationService: mocks.mockIncomingTranslation,
        outgoingTTSFactory: { _, _ in mocks.mockOutgoingTTS },
        incomingTTSFactory: { _, _ in mocks.mockIncomingTTS },
        languagePairManager: mocks.languagePairManager,
        echoGateClock: TestClock(),
        noticeClock: TestClock()
    )
    coordinator.clauseSplitSetting = { split }
    return coordinator
}

/// The STT result for segment `id` (the mock STT does not read segments: tests inject results).
private func result(_ text: String, id: UInt64, _ kind: SegmentKind = .final) -> TranscriptionResult {
    TranscriptionResult(
        text: text, confidence: 1, locale: Locale(identifier: "en-US"), capturedAt: .now, audioDuration: 1,
        segmentID: id, kind: kind
    )
}

@Suite("AudioCoordinator clause split (FR-CS.2)", .serialized) @MainActor
struct AudioCoordinatorClauseSplitTests {

    @Test("the first part is spoken while the second still translates; Translating stays on (REQ-CS-11, -12, -18)")
    func partZeroSpokenWhilePartOneHeld() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        let translation = mocks.mockOutgoingTranslation
        let tts = mocks.mockOutgoingTTS
        await coordinator.start()
        translation.holdTexts = [part1]

        await mocks.mockOutgoingSTT.injectTranscription(result(sentenceText, id: 1))
        #expect(await waitUntil { await tts.speakCalls.map(\.text) == [spoken0] })
        #expect(await waitUntil { translation.heldCount == 1 })
        #expect(coordinator.transcript.map(\.original) == [sentenceText], "one entry per sentence")
        #expect(coordinator.transcript.first?.translation == spoken0)
        #expect(coordinator.outgoingTranslation == spoken0)
        #expect(coordinator.isOutgoingTranslating)

        translation.releaseHeld()
        #expect(await waitUntil { await tts.speakCalls.map(\.text) == [spoken0, spoken1] })
        #expect(coordinator.transcript.map(\.translation) == [joined])
        #expect(coordinator.outgoingTranslation == joined)
        #expect(await waitUntil { !coordinator.isOutgoingTranslating })
        await coordinator.stop()
    }

    @Test("Pause between the parts: the second is shown, not spoken (REQ-CS-14)")
    func pauseBetweenPartsShowsNotSpeaks() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        let translation = mocks.mockOutgoingTranslation
        let tts = mocks.mockOutgoingTTS
        await coordinator.start()
        translation.holdTexts = [part1]

        await mocks.mockOutgoingSTT.injectTranscription(result(sentenceText, id: 1))
        #expect(await waitUntil { await tts.speakCalls.count == 1 && translation.heldCount == 1 })
        await coordinator.pause()
        translation.releaseHeld()
        #expect(await waitUntil { coordinator.transcript.first?.translation == joined })
        #expect(await waitUntil { !coordinator.isOutgoingTranslating })
        #expect(await tts.speakCalls.map(\.text) == [spoken0])
        await coordinator.stop()
    }

    @Test("Pause then Resume between the parts: the second is still shown, not spoken (REQ-CS-14)")
    func pauseResumeBetweenPartsStillSilent() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        let translation = mocks.mockOutgoingTranslation
        let tts = mocks.mockOutgoingTTS
        await coordinator.start()
        translation.holdTexts = [part1]

        await mocks.mockOutgoingSTT.injectTranscription(result(sentenceText, id: 1))
        #expect(await waitUntil { await tts.speakCalls.count == 1 && translation.heldCount == 1 })
        await coordinator.pause()
        coordinator.resume()
        translation.releaseHeld()
        #expect(await waitUntil { coordinator.transcript.first?.translation == joined })
        #expect(await waitUntil { !coordinator.isOutgoingTranslating })
        #expect(await tts.speakCalls.map(\.text) == [spoken0])
        await coordinator.stop()
    }

    @Test("Pause landing during a part's speak stops it again (UI-B1 per part)")
    func pauseDuringPartSpeakStopsIt() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        let translation = mocks.mockOutgoingTranslation
        let tts = mocks.mockOutgoingTTS
        await coordinator.start()
        translation.holdTexts = [part1]

        await mocks.mockOutgoingSTT.injectTranscription(result(sentenceText, id: 1))
        #expect(await waitUntil { await tts.speakCalls.count == 1 && translation.heldCount == 1 })
        await tts.setHoldNextSpeak()
        translation.releaseHeld()
        #expect(await waitUntil { await tts.isHoldingSpeak })
        await coordinator.pause()
        await tts.resetStopSpeakingCalled()   // Pause's own stop: the guard's must come after the speak
        await tts.releaseHeldSpeak()
        #expect(await waitUntil { await tts.speakCalls.map(\.text) == [spoken0, spoken1] })
        #expect(await waitUntil { await tts.stopSpeakingCalled }, "the guard stopped the late speak")
        #expect(await waitUntil { !(await tts.isSpeaking) }, "nothing plays while paused")
        await coordinator.stop()
    }

    @Test("Stop between the parts: nothing more is spoken; the next session's Translating is kept (REQ-CS-15)")
    func stopBetweenPartsSpeaksNothingMore() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        let translation = mocks.mockOutgoingTranslation
        let tts = mocks.mockOutgoingTTS
        await coordinator.start()
        translation.holdTexts = [part1]

        await mocks.mockOutgoingSTT.injectTranscription(result(sentenceText, id: 1))
        #expect(await waitUntil { await tts.speakCalls.count == 1 && translation.heldCount == 1 })
        await coordinator.stop()
        translation.releaseHeld()
        #expect(await waitUntil { translation.heldCount == 0 }, "the cancelled part freed its own call")
        await mainQueueHop()
        #expect(await tts.speakCalls.map(\.text) == [spoken0])
        #expect(coordinator.transcript.first?.translation == spoken0)
        #expect(coordinator.transcript.first?.skipped == false, "a cancellation is not a failure")
        #expect(coordinator.transcript.first?.partlySkipped == false)
        #expect(coordinator.ttsNotice == nil)

        await coordinator.start()
        translation.holdNext = true
        let next = Task { await coordinator.deliverOutgoing("hola") }
        #expect(await waitUntil { translation.heldCount == 1 && coordinator.isOutgoingTranslating })
        await mainQueueHop()
        #expect(coordinator.isOutgoingTranslating, "the old sentence's end did not clear it")
        translation.releaseHeld()
        await next.value
        await coordinator.stop()
    }

    @Test("a cancelled delivery speaks no later part even if the translator ignores cancellation")
    func cancelledDeliveryWithStubbornPartOne() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        let tts = mocks.mockOutgoingTTS
        await coordinator.start()
        let gate = AsyncGate()
        let sentence = SentenceTranslation(sentenceText, split: true) { part in
            if part == part1 { await gate.wait() }   // ignores cancellation
            return "TRANSLATED: \(part)"
        }
        let delivery = Task { await coordinator.deliverOutgoing(sentenceText, translation: sentence) }
        #expect(await waitUntil { await tts.speakCalls.count == 1 })

        delivery.cancel()
        gate.open()
        await delivery.value
        #expect(await tts.speakCalls.map(\.text) == [spoken0])
        #expect(coordinator.transcript.first?.translation == spoken0)
        #expect(coordinator.ttsNotice == nil)
        await coordinator.stop()
    }

    @Test("the second part fails: the first stays spoken and shown, the entry is partly skipped (REQ-CS-16)")
    func partOneFailureKeepsPartZero() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        let tts = mocks.mockOutgoingTTS
        await coordinator.start()
        mocks.mockOutgoingTranslation.failTexts = [part1: TranslationError.timedOut]

        await mocks.mockOutgoingSTT.injectTranscription(result(sentenceText, id: 1))
        #expect(await waitUntil { coordinator.transcript.first?.partlySkipped == true })
        #expect(await tts.speakCalls.map(\.text) == [spoken0])
        #expect(coordinator.transcript.first?.translation == spoken0)
        #expect(coordinator.transcript.first?.skipped == false)
        #expect(coordinator.ttsNotice != nil)
        #expect(await waitUntil { !coordinator.isOutgoingTranslating })
        await coordinator.stop()
    }

    @Test("the second part cancelled under a live delivery: partly skipped, no notice")
    func partOneCancelledMarksPartlySkipped() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        let translation = mocks.mockOutgoingTranslation
        let tts = mocks.mockOutgoingTTS
        await coordinator.start()
        translation.holdTexts = [part1]
        let sentence = SentenceTranslation(sentenceText, split: true) { part in
            try await translation.translate(text: part, from: .init(identifier: "en"), to: .init(identifier: "es"))
        }
        let delivery = Task { await coordinator.deliverOutgoing(sentenceText, translation: sentence) }
        #expect(await waitUntil { await tts.speakCalls.count == 1 && translation.heldCount == 1 })

        sentence.tasks[1].cancel()   // as the committer's cancel of a sentence, the delivery itself live
        await delivery.value
        #expect(coordinator.transcript.first?.partlySkipped == true)
        #expect(coordinator.transcript.first?.translation == spoken0)
        #expect(coordinator.transcript.first?.skipped == false)
        #expect(coordinator.ttsNotice == nil)
        #expect(await tts.speakCalls.map(\.text) == [spoken0])
        await coordinator.stop()
    }

    @Test("the first part fails: the sentence is skipped and the second translation cancelled (REQ-CS-16)")
    func partZeroFailureSkipsSentence() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        let translation = mocks.mockOutgoingTranslation
        await coordinator.start()
        translation.holdTexts = [part0, part1]
        translation.failTexts = [part0: TranslationError.timedOut]

        await mocks.mockOutgoingSTT.injectTranscription(result(sentenceText, id: 1))
        #expect(await waitUntil { translation.heldCount == 2 })
        translation.releaseHeld(part0)
        #expect(await waitUntil { coordinator.transcript.first?.skipped == true })
        #expect(await waitUntil { translation.heldCount == 0 }, "the second part was cancelled")
        #expect(await mocks.mockOutgoingTTS.speakCalls.isEmpty)
        #expect(coordinator.transcript.first?.translation == nil)
        #expect(coordinator.ttsNotice != nil)
        await coordinator.stop()
    }

    @Test("a mute turn drops the whole held sentence and cancels both parts (REQ-CS-13)")
    func muteTurnCancelsBothParts() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        let translation = mocks.mockOutgoingTranslation
        await coordinator.start()
        translation.holdTexts = [part0, part1]
        await mocks.mockOutgoingSTT.injectTranscription(result(sentenceText, id: 1, .tentative))
        #expect(await waitUntil { translation.heldCount == 2 })

        coordinator.suppressNextOutgoingTurn()
        await mocks.mockVADFactory.injectBoundary(.commit(1))
        #expect(await waitUntil { translation.heldCount == 0 }, "both parts cancelled")
        #expect(!coordinator.suppressNextOutgoingTurnFlag, "the turn was used once, by the whole sentence")
        #expect(coordinator.transcript.isEmpty)
        #expect(await mocks.mockOutgoingTTS.speakCalls.isEmpty)
        await coordinator.stop()
    }

    @Test("an echo of their translation drops the whole held sentence and cancels both parts (REQ-CS-13)")
    func echoDropCancelsBothParts() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        let translation = mocks.mockOutgoingTranslation
        await coordinator.start()
        coordinator.selfEchoGuard.played(sentenceText, at: .now)
        translation.holdTexts = [part0, part1]
        await mocks.mockOutgoingSTT.injectTranscription(result(sentenceText, id: 1, .tentative))
        #expect(await waitUntil { translation.heldCount == 2 })

        await mocks.mockVADFactory.injectBoundary(.commit(1))
        #expect(await waitUntil { translation.heldCount == 0 }, "both parts cancelled")
        #expect(coordinator.transcript.isEmpty)
        #expect(coordinator.ttsNotice != nil)
        #expect(await mocks.mockOutgoingTTS.speakCalls.isEmpty)
        await coordinator.stop()
    }

    @Test("incoming: each spoken part and the joined translation reach the self-echo guard (REQ-CS-17)")
    func incomingRegistersPartsAndJoined() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        let translation = mocks.mockIncomingTranslation
        let tts = mocks.mockIncomingTTS
        await coordinator.start(captureTarget: callTarget)
        #expect(await waitUntil { coordinator.isIncomingActive })
        translation.holdTexts = [part1]

        await mocks.mockIncomingSTT.injectTranscription(result(sentenceText, id: 1))
        #expect(await waitUntil { await tts.speakCalls.map(\.text) == [spoken0] && translation.heldCount == 1 })
        #expect(coordinator.selfEchoGuard.isEcho(spoken0, at: .now), "the first part, as soon as it is spoken")
        #expect(coordinator.isIncomingTranslating)

        translation.releaseHeld()
        #expect(await waitUntil { await tts.speakCalls.map(\.text) == [spoken0, spoken1] })
        #expect(await waitUntil { !coordinator.isIncomingTranslating })
        #expect(coordinator.selfEchoGuard.isEcho(joined, at: .now))
        #expect(coordinator.selfEchoGuard.isEcho(spoken1, at: .now))
        #expect(coordinator.transcript.map(\.translation) == [joined])
        await coordinator.stop()
    }

    @Test("a tentative translates both parts before its commit; the commit speaks them in order (REQ-CS-10)")
    func tentativeTranslatesBothBeforeCommit() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        let translation = mocks.mockOutgoingTranslation
        let tts = mocks.mockOutgoingTTS
        await coordinator.start()

        await mocks.mockOutgoingSTT.injectTranscription(result(sentenceText, id: 1, .tentative))
        #expect(await waitUntil { translation.translateCallCount == 2 })
        await mainQueueHop()
        #expect(coordinator.transcript.isEmpty)
        #expect(await tts.speakCalls.isEmpty)

        await mocks.mockVADFactory.injectBoundary(.commit(1))
        #expect(await waitUntil { await tts.speakCalls.map(\.text) == [spoken0, spoken1] })
        #expect(coordinator.transcript.map(\.translation) == [joined])
        #expect(translation.translateCallCount == 2, "not translated again at commit")
        await coordinator.stop()
    }

    @Test("clause split off: the whole sentence is translated and spoken once")
    func splitOffSpeaksWhole() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, split: false)
        let tts = mocks.mockOutgoingTTS
        await coordinator.start()

        await mocks.mockOutgoingSTT.injectTranscription(result(sentenceText, id: 1))
        #expect(await waitUntil { await tts.speakCalls.count == 1 })
        #expect(await tts.speakCalls.map(\.text) == ["TRANSLATED: \(sentenceText)"])
        #expect(mocks.mockOutgoingTranslation.translateCallCount == 1)
        #expect(coordinator.transcript.map(\.translation) == ["TRANSLATED: \(sentenceText)"])
        await coordinator.stop()
    }
}
