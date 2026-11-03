import Foundation
import Testing
@testable import TranslateCall

private let callTarget = CaptureTarget.app(bundleID: "com.test.call")

@MainActor
private func makeCoordinator(_ mocks: CoordinatorMocks) -> AudioCoordinator {
    AudioCoordinator(
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
}

/// The STT result for segment `id` (the mock STT does not read segments: tests inject results).
private func result(_ text: String, id: UInt64, _ kind: SegmentKind = .tentative) -> TranscriptionResult {
    TranscriptionResult(
        text: text, confidence: 1, locale: Locale(identifier: "es-ES"), capturedAt: .now, audioDuration: 1,
        segmentID: id, kind: kind
    )
}

@Suite("AudioCoordinator early processing (FR-QS.5)", .serialized) @MainActor
struct AudioCoordinatorEarlyProcessingTests {

    @Test("a tentative is translated at once but shown and spoken only at its commit")
    func tentativeSpokenAtCommit() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()

        await mocks.mockOutgoingSTT.injectTranscription(result("hola", id: 1))
        #expect(await waitUntil { mocks.mockOutgoingTranslation.translateCallCount == 1 })
        #expect(await waitUntil { coordinator.outgoingTranscription == "hola" }, "live caption may show it")
        await mainQueueHop()
        #expect(coordinator.transcript.isEmpty)
        #expect(await mocks.mockOutgoingTTS.speakCalls.isEmpty)

        await mocks.mockVADFactory.injectBoundary(.commit(1))
        #expect(await waitUntil { await mocks.mockOutgoingTTS.speakCalls.count == 1 })
        #expect(await mocks.mockOutgoingTTS.speakCalls.first?.text == "TRANSLATED: hola")
        #expect(coordinator.transcript.map(\.original) == ["hola"])
        #expect(coordinator.transcript.first?.translation == "TRANSLATED: hola")
        #expect(mocks.mockOutgoingTranslation.translateCallCount == 1, "not translated again at commit")
        await coordinator.stop()
    }

    @Test("a retracted tentative is never shown nor spoken")
    func retractedNeverShown() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()

        await mocks.mockOutgoingSTT.injectTranscription(result("creo", id: 1))
        await mocks.mockVADFactory.injectBoundary(.retract(1))
        await mocks.mockOutgoingSTT.injectTranscription(result("creo que sí", id: 2, .final))
        #expect(await waitUntil { await mocks.mockOutgoingTTS.speakCalls.count == 1 })
        #expect(await mocks.mockOutgoingTTS.speakCalls.map(\.text) == ["TRANSLATED: creo que sí"])
        #expect(coordinator.transcript.map(\.original) == ["creo que sí"])
        await coordinator.stop()
    }

    @Test("a commit whose delivery is still translating when Pause comes is shown, not spoken")
    func pausedCommitShownNotSpoken() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()
        mocks.mockOutgoingTranslation.holdNext = true
        await mocks.mockOutgoingSTT.injectTranscription(result("hola", id: 1))
        #expect(await waitUntil { mocks.mockOutgoingTranslation.isHolding })

        await mocks.mockVADFactory.injectBoundary(.commit(1))
        #expect(await waitUntil { coordinator.transcript.map(\.original) == ["hola"] })
        await coordinator.pause()
        mocks.mockOutgoingTranslation.releaseHeld()
        #expect(await waitUntil { coordinator.transcript.first?.translation == "TRANSLATED: hola" })
        await mainQueueHop()
        #expect(await mocks.mockOutgoingTTS.speakCalls.isEmpty)
        await coordinator.stop()
    }

    @Test("a commit that comes while paused is dropped, as a sentence delivered while paused (REQ-UI-50)")
    func commitWhilePausedDropped() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()
        await mocks.mockOutgoingSTT.injectTranscription(result("hola", id: 1))
        #expect(await waitUntil { mocks.mockOutgoingTranslation.translateCallCount == 1 })

        await coordinator.pause()
        await mocks.mockVADFactory.injectBoundary(.commit(1))
        #expect(await waitUntil { coordinator.outgoingCommitter?.heldCount == 0 }, "delivered (dropped) while paused")
        coordinator.resume()
        await mocks.mockOutgoingSTT.injectTranscription(result("vale", id: 2, .final))
        #expect(await waitUntil { await mocks.mockOutgoingTTS.speakCalls.count == 1 })
        #expect(await mocks.mockOutgoingTTS.speakCalls.map(\.text) == ["TRANSLATED: vale"])
        #expect(coordinator.transcript.map(\.original) == ["vale"])
        await coordinator.stop()
    }

    @Test("a mute turn applies at the commit, and an empty result does not use it up")
    func muteTurnAtCommit() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()
        coordinator.suppressNextOutgoingTurn()

        await mocks.mockOutgoingSTT.injectTranscription(result("", id: 1, .final))
        await mocks.mockOutgoingSTT.injectTranscription(result("secreto", id: 2))
        await mocks.mockVADFactory.injectBoundary(.commit(2))
        #expect(await waitUntil { !coordinator.suppressNextOutgoingTurnFlag })
        await mocks.mockOutgoingSTT.injectTranscription(result("público", id: 3, .final))
        #expect(await waitUntil { await mocks.mockOutgoingTTS.speakCalls.count == 1 })
        #expect(await mocks.mockOutgoingTTS.speakCalls.map(\.text) == ["TRANSLATED: público"])
        #expect(coordinator.transcript.map(\.original) == ["público"])
        await coordinator.stop()
    }

    @Test("stop while a committed sentence awaits its held translation: nothing completed, nothing spoken")
    func stopDropsHeldTentative() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()
        mocks.mockOutgoingTranslation.holdNext = true
        await mocks.mockOutgoingSTT.injectTranscription(result("hola", id: 1))
        #expect(await waitUntil { mocks.mockOutgoingTranslation.isHolding })
        await mocks.mockVADFactory.injectBoundary(.commit(1))
        #expect(await waitUntil { coordinator.transcript.map(\.original) == ["hola"] })

        await coordinator.stop()
        mocks.mockOutgoingTranslation.releaseHeld()
        await mainQueueHop()
        #expect(coordinator.transcript.first?.translation == nil)
        #expect(await mocks.mockOutgoingTTS.speakCalls.isEmpty)
    }

    @Test("incoming: stop while a committed sentence awaits its held translation speaks nothing")
    func stopDropsHeldIncomingTentative() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        #expect(await waitUntil { coordinator.isIncomingActive })
        mocks.mockIncomingTranslation.holdNext = true
        await mocks.mockIncomingSTT.injectTranscription(result("hello", id: 1))
        #expect(await waitUntil { mocks.mockIncomingTranslation.isHolding })
        await mocks.mockIncomingVAD.injectBoundary(.commit(1))
        #expect(await waitUntil { coordinator.transcript.map(\.original) == ["hello"] })

        await coordinator.stop()
        mocks.mockIncomingTranslation.releaseHeld()
        await mainQueueHop()
        #expect(coordinator.transcript.first?.translation == nil)
        #expect(await mocks.mockIncomingTTS.speakCalls.isEmpty)
    }

    @Test("a cancelled delivery speaks nothing even if the translator ignores cancellation")
    func cancelledDeliveryWithStubbornTranslator() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()
        let gate = AsyncGate()
        let stubborn = Task<String, Error> { await gate.wait(); return "late" }   // ignores cancel
        let delivery = Task { await coordinator.deliverOutgoing("hola", translation: stubborn) }
        #expect(await waitUntil { coordinator.transcript.map(\.original) == ["hola"] })

        delivery.cancel()
        gate.open()
        await delivery.value
        #expect(await mocks.mockOutgoingTTS.speakCalls.isEmpty)
        #expect(coordinator.transcript.first?.translation == nil)
        #expect(coordinator.transcript.first?.skipped == false, "a cancellation is not a failure")
        #expect(coordinator.ttsNotice == nil)
        await coordinator.stop()
    }

    @Test("the incoming direction holds a tentative until its commit too")
    func incomingTentativeSpokenAtCommit() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        #expect(await waitUntil { coordinator.isIncomingActive })

        await mocks.mockIncomingSTT.injectTranscription(result("hello", id: 1))
        #expect(await waitUntil { mocks.mockIncomingTranslation.translateCallCount == 1 })
        await mainQueueHop()
        #expect(coordinator.transcript.isEmpty)

        await mocks.mockIncomingVAD.injectBoundary(.commit(1))
        #expect(await waitUntil { await mocks.mockIncomingTTS.speakCalls.count == 1 })
        #expect(coordinator.transcript.map(\.original) == ["hello"])
        #expect(coordinator.transcript.first?.direction == .incoming)
        await coordinator.stop()
    }
}
