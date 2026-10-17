import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

private let callTarget = CaptureTarget.app(bundleID: "com.test.call")

@MainActor
private func makeCoordinator(_ mocks: CoordinatorMocks, gateClock: TestClock = TestClock()) -> AudioCoordinator {
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
        echoGateClock: gateClock,
        noticeClock: TestClock()
    )
}

private func transcript(_ text: String) -> TranscriptionResult {
    TranscriptionResult(text: text, confidence: 1, locale: Locale(identifier: "es-ES"), capturedAt: .now, audioDuration: 1)
}

/// Feeds one loud buffer to `inject` and waits until `vad` has seen it; returns its peak there.
@MainActor
private func peakAtVAD(_ vad: MockVADService, inject: () async -> Void) async -> Float? {
    let before = await vad.receivedPeaks.count
    await inject()
    guard await waitUntil({ await vad.receivedPeaks.count == before + 1 }) else { return nil }
    return await vad.receivedPeaks.last
}

@Suite("AudioCoordinator session state for the UI (M9 UI core)", .serialized) @MainActor
struct AudioCoordinatorSessionTests {

    // MARK: Transcript and flags (design §4.1)

    @Test("a sentence is appended when STT delivers it and completed when translated")
    func transcriptAppendAndComplete() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()
        #expect(coordinator.sessionStartedAt != nil)

        mocks.mockOutgoingTranslation.holdNext = true
        await mocks.mockOutgoingSTT.injectTranscription(transcript("hola"))
        #expect(await waitUntil { coordinator.isOutgoingTranslating })
        #expect(coordinator.transcript.map(\.original) == ["hola"])
        #expect(coordinator.transcript.first?.translation == nil)
        #expect(coordinator.transcript.first?.direction == .outgoing)

        mocks.mockOutgoingTranslation.releaseHeld()
        #expect(await waitUntil { !coordinator.isOutgoingTranslating })
        #expect(coordinator.transcript.first?.translation == "TRANSLATED: hola")
        await coordinator.stop()
        #expect(coordinator.sessionStartedAt == nil)
        #expect(coordinator.transcript.count == 1, "kept after Stop until the next Start")
    }

    @Test("a failed translation marks the entry skipped")
    func failedTranslationSkipped() async {
        let mocks = CoordinatorMocks()
        mocks.mockOutgoingTranslation.errors = [TranslationError.timedOut]
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()

        await mocks.mockOutgoingSTT.injectTranscription(transcript("uno"))
        #expect(await waitUntil { coordinator.transcript.first?.skipped == true })
        #expect(coordinator.transcript.first?.translation == nil)
        #expect(!coordinator.isOutgoingTranslating)
        await coordinator.stop()
    }

    @Test("the transcript keeps the newest 200 entries and is cleared at the next start (REQ-UI-44)")
    func transcriptCapAndClear() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        for index in 0..<205 { _ = coordinator.appendTranscript(.incoming, "s\(index)") }
        #expect(coordinator.transcript.count == TranscriptEntry.limit)
        #expect(coordinator.transcript.first?.original == "s5")
        #expect(coordinator.transcript.last?.original == "s204")

        await coordinator.start()
        #expect(coordinator.transcript.isEmpty)
        await coordinator.stop()
    }

    @Test("the incoming VAD drives isIncomingSpeechActive; teardown clears it")
    func incomingSpeechActive() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        #expect(await waitUntil { coordinator.isIncomingActive })

        await mocks.mockIncomingVAD.injectVADState(true)
        #expect(await waitUntil { coordinator.isIncomingSpeechActive })
        await coordinator.stop()
        #expect(!coordinator.isIncomingSpeechActive)
    }

    // MARK: Pause (D-5, REQ-UI-50…52)

    @Test("pause silences both directions before their VADs and stops both TTS")
    func pauseSilencesBothDirections() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        #expect(await waitUntil { coordinator.isIncomingActive })

        await coordinator.pause()
        #expect(coordinator.isPaused)
        #expect(await mocks.mockOutgoingTTS.stopSpeakingCalled)
        #expect(await mocks.mockIncomingTTS.stopSpeakingCalled)
        let micPeak = await peakAtVAD(mocks.mockVADFactory) {
            mocks.mockAudioCapture.injectBuffer(makePCMBuffer(frames: 160, fill: 0.5))
        }
        let callPeak = await peakAtVAD(mocks.mockIncomingVAD) {
            await mocks.mockSystemCapture.injectBuffer(makePCMBuffer(frames: 160, fill: 0.5))
        }
        #expect(micPeak == 0)
        #expect(callPeak == 0)

        coordinator.resume()
        let resumed = await peakAtVAD(mocks.mockVADFactory) {
            mocks.mockAudioCapture.injectBuffer(makePCMBuffer(frames: 160, fill: 0.5))
        }
        #expect(resumed == 0.5, "from the next buffer, nothing reloaded")
        #expect(mocks.mockAudioCapture.startCount == 1)
        await coordinator.stop()
    }

    @Test("text delivered while paused is not translated; after Resume it is")
    func pausedTextDropped() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()
        await coordinator.pause()

        await mocks.mockOutgoingSTT.injectTranscription(transcript("ignored"))
        #expect(await waitUntil { coordinator.outgoingTranscription == "ignored" })   // consumed while paused
        coordinator.resume()
        await mocks.mockOutgoingSTT.injectTranscription(transcript("kept"))
        #expect(await waitUntil { mocks.mockOutgoingTranslation.translateCallCount == 1 })
        #expect(mocks.mockOutgoingTranslation.lastTranslatedText == "kept")
        #expect(coordinator.transcript.map(\.original) == ["kept"])
        await coordinator.stop()
    }

    @Test("a sentence whose translation returns after Pause is shown, not spoken")
    func translationReturningAfterPauseIsNotSpoken() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()
        mocks.mockOutgoingTranslation.holdNext = true
        await mocks.mockOutgoingSTT.injectTranscription(transcript("hola"))
        #expect(await waitUntil { mocks.mockOutgoingTranslation.isHolding })

        await coordinator.pause()
        mocks.mockOutgoingTranslation.releaseHeld()
        #expect(await waitUntil { coordinator.transcript.first?.translation == "TRANSLATED: hola" })
        #expect(await mocks.mockOutgoingTTS.speakCalls.isEmpty)
        await coordinator.stop()
    }

    @Test("pause outside a session does nothing; pause and resume leave the echo gate working; Stop resets")
    func pauseEdges() async {
        let mocks = CoordinatorMocks()
        let gateClock = TestClock()
        let coordinator = makeCoordinator(mocks, gateClock: gateClock)
        let micPeak = {
            await peakAtVAD(mocks.mockVADFactory) { mocks.mockAudioCapture.injectBuffer(makePCMBuffer(frames: 160, fill: 0.5)) }
        }
        await coordinator.pause()
        #expect(!coordinator.isPaused)

        coordinator.listeningMode = .speakers
        await coordinator.start(captureTarget: callTarget)
        coordinator.isIncomingSpeaking = true   // their translation plays on speakers: the echo gate mutes
        #expect(await micPeak() == 0)
        #expect(await waitUntil { coordinator.isMicPaused })

        await coordinator.pause()
        coordinator.resume()
        #expect(coordinator.isMicPaused, "pausing is not the echo gate: it is never reset")
        #expect(await micPeak() == 0, "the echo gate still mutes after Resume")
        coordinator.isIncomingSpeaking = false
        gateClock.advance(by: .milliseconds(300))
        #expect(await micPeak() == 0.5, "and reopens by its own tail rule")

        await coordinator.pause()
        await coordinator.stop()
        #expect(!coordinator.isPaused)
        #expect(coordinator.pauseGate == nil)
    }

    @Test("Retry while paused re-activates incoming behind the same gate: still silent")
    func retryWhilePausedStaysSilent() async {
        let mocks = CoordinatorMocks()
        await mocks.mockSystemCapture.setThrowOnActivate(SystemAudioCaptureError.targetNotFound(bundleID: "com.test.call"))
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        #expect(await waitUntil { if case .stopped = coordinator.incomingStatus { true } else { false } })
        await coordinator.pause()

        await mocks.mockSystemCapture.setThrowOnActivate(nil)
        coordinator.retryIncoming(captureTarget: callTarget)
        #expect(await waitUntil { coordinator.isIncomingActive })
        let callPeak = await peakAtVAD(mocks.mockIncomingVAD) {
            await mocks.mockSystemCapture.injectBuffer(makePCMBuffer(frames: 160, fill: 0.5))
        }
        #expect(callPeak == 0)
        await coordinator.stop()
    }
}
