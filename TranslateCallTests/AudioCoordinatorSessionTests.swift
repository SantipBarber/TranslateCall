import AVFoundation
import Combine
import Foundation
import Testing
@testable import TranslateCall

private let callTarget = CaptureTarget.app(bundleID: "com.test.call")

/// A fresh outgoing STT per session: the mock's stream ends at deactivate, so a restart needs a new one.
@MainActor
private final class STTBox {
    private(set) var current: MockSpeechRecognizerService?
    func make() -> MockSpeechRecognizerService {
        let stt = MockSpeechRecognizerService()
        current = stt
        return stt
    }
}

@MainActor
private func makeCoordinator(
    _ mocks: CoordinatorMocks, gateClock: TestClock = TestClock(), outgoingSTT: STTBox? = nil
) -> AudioCoordinator {
    AudioCoordinator(
        audioCapture: mocks.mockAudioCapture,
        systemCapture: mocks.mockSystemCapture,
        outgoingVADFactory: { mocks.mockVADFactory },
        incomingVADFactory: { mocks.mockIncomingVAD },
        outgoingSTTFactory: { _ in outgoingSTT?.make() ?? mocks.mockOutgoingSTT },
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
        #expect(await waitUntil { coordinator.isOutgoingTranslating && mocks.mockOutgoingTranslation.isHolding })
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

    /// Resume lands after the result arrives but before the committer delivers it (the race that
    /// flaked `pausedTextDropped`): the sentence was heard while paused, so it is still dropped.
    @Test("text heard while paused is dropped even if Resume comes before its delivery")
    func pausedTextDroppedWhenResumedBeforeDelivery() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        await coordinator.pause()
        // Fires synchronously as each caption is set, inside the observer, before delivery runs.
        let resumeOnCaption = coordinator.$outgoingTranscription.merge(with: coordinator.$incomingTranscription)
            .sink { if $0 == "ignored" { coordinator.resume() } }
        defer { resumeOnCaption.cancel() }

        await mocks.mockOutgoingSTT.injectTranscription(transcript("ignored"))
        #expect(await waitUntil { !coordinator.isPaused })
        await coordinator.pause()
        await mocks.mockIncomingSTT.injectTranscription(transcript("ignored"))
        #expect(await waitUntil { !coordinator.isPaused })
        await mocks.mockOutgoingSTT.injectTranscription(transcript("kept"))
        await mocks.mockIncomingSTT.injectTranscription(transcript("kept"))
        #expect(await waitUntil {
            mocks.mockOutgoingTranslation.translateCallCount == 1 && mocks.mockIncomingTranslation.translateCallCount == 1
        })
        #expect(mocks.mockOutgoingTranslation.lastTranslatedText == "kept")
        #expect(mocks.mockIncomingTranslation.lastTranslatedText == "kept")
        #expect(coordinator.transcript.map(\.original) == ["kept", "kept"])
        await coordinator.stop()
    }

    /// UI-B1: `speak` and Pause's `stopSpeaking` hop to the TTS actor separately, and actor jobs are
    /// not FIFO, so the sentence can be queued after the stop. It must not stay playing while paused.
    @Test("a sentence whose speak reaches the TTS after Pause's stop is stopped again")
    func speakLandingAfterPauseIsStopped() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        let tts = mocks.mockOutgoingTTS
        await coordinator.start()
        await tts.setHoldNextSpeak()

        await mocks.mockOutgoingSTT.injectTranscription(transcript("hola"))
        #expect(await waitUntil { await tts.isHoldingSpeak })
        await coordinator.pause()
        await tts.releaseHeldSpeak()
        #expect(await waitUntil { await tts.speakCalls.count == 1 })
        #expect(await waitUntil { !(await tts.isSpeaking) }, "nothing plays while paused")
        await coordinator.stop()
    }

    /// UI-B2: Stop cannot interrupt a translator that ignores cancellation (the Apple bridge), so the
    /// old session's sentence ends late; its cleanup must not touch the new session's state.
    @Test("an old session's sentence ending late does not clear the new session's Translating")
    func staleSentenceKeepsNewTranslating() async {
        let mocks = CoordinatorMocks()
        let stt = STTBox()
        let coordinator = makeCoordinator(mocks, outgoingSTT: stt)
        let translation = mocks.mockOutgoingTranslation
        await coordinator.start()
        translation.holdNext = true
        await stt.current?.injectTranscription(transcript("old"))
        #expect(await waitUntil { translation.heldCount == 1 })
        await coordinator.stop()

        await coordinator.start()
        translation.holdNext = true
        await stt.current?.injectTranscription(transcript("new"))
        #expect(await waitUntil { translation.heldCount == 2 && coordinator.isOutgoingTranslating })
        translation.releaseHeld()   // the old session's sentence
        #expect(await waitUntil(timeout: .milliseconds(300)) { !coordinator.isOutgoingTranslating } == false,
                "still translating the new sentence")
        translation.releaseHeld()
        #expect(await waitUntil { !coordinator.isOutgoingTranslating })
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

    @Test("stopping during an in-flight translation cancels it: nothing completed, nothing spoken")
    func teardownCancelsInFlightTranslation() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()
        mocks.mockOutgoingTranslation.holdNext = true
        await mocks.mockOutgoingSTT.injectTranscription(transcript("hola"))
        #expect(await waitUntil { mocks.mockOutgoingTranslation.isHolding })

        await coordinator.stop()
        mocks.mockOutgoingTranslation.releaseHeld()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.transcript.first?.translation == nil)
        #expect(await mocks.mockOutgoingTTS.speakCalls.isEmpty)
    }

    @Test("a translation handed to deliver is cancelled when the sentence is dropped (paused, mute turn, empty)")
    func droppedDeliveryCancelsTranslation() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()
        func started() -> Task<String, Error> { Task { try await Task.sleep(for: .seconds(60)); return "x" } }

        coordinator.suppressNextOutgoingTurn()
        let muted = started()
        await coordinator.deliverOutgoing("muted", translation: muted)
        #expect(await muted.result.isFailure)

        let empty = started()
        await coordinator.deliverOutgoing("", translation: empty)
        #expect(await empty.result.isFailure)

        await coordinator.pause()
        let pausedOut = started()
        let pausedIn = started()
        await coordinator.deliverOutgoing("paused", translation: pausedOut)
        await coordinator.deliverIncoming("paused", translation: pausedIn)
        #expect(await pausedOut.result.isFailure)
        #expect(await pausedIn.result.isFailure)

        #expect(coordinator.transcript.isEmpty)
        #expect(await mocks.mockOutgoingTTS.speakCalls.isEmpty)
        #expect(await mocks.mockIncomingTTS.speakCalls.isEmpty)
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

    // MARK: Clause split read at session start (REQ-CS-20)

    @Test("clause split is read at start() and stays fixed until the next start (REQ-CS-20)")
    func clauseSplitReadAtStart() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        var settingOn = true
        coordinator.clauseSplitSetting = { settingOn }

        await coordinator.start(captureTarget: callTarget)
        #expect(coordinator.isClauseSplitOn)
        settingOn = false
        #expect(coordinator.isClauseSplitOn, "a mid-session change waits for the next start")
        await coordinator.stop()

        await coordinator.start(captureTarget: callTarget)
        #expect(!coordinator.isClauseSplitOn)
        await coordinator.stop()
    }

    @Test("no clause-split setting: the session runs with the flag off (REQ-CS-20)")
    func clauseSplitOffWithoutSetting() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        #expect(coordinator.clauseSplitSetting == nil)

        await coordinator.start(captureTarget: callTarget)
        #expect(!coordinator.isClauseSplitOn)
        await coordinator.stop()
    }
}

private extension Result {
    var isFailure: Bool { if case .failure = self { true } else { false } }
}
