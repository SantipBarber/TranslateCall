import Foundation
import Testing
@testable import TranslateCall

@MainActor
private func makeCoordinator(
    _ mocks: CoordinatorMocks, noticeClock: TestClock, vadGate: AsyncGate? = nil
) -> AudioCoordinator {
    AudioCoordinator(
        audioCapture: mocks.mockAudioCapture,
        systemCapture: mocks.mockSystemCapture,
        outgoingVADFactory: {
            await vadGate?.wait()
            return mocks.mockVADFactory
        },
        incomingVADFactory: { mocks.mockIncomingVAD },
        outgoingSTTFactory: { _ in mocks.mockOutgoingSTT },
        incomingSTTFactory: { _ in mocks.mockIncomingSTT },
        outgoingTranslationService: mocks.mockOutgoingTranslation,
        incomingTranslationService: mocks.mockIncomingTranslation,
        outgoingTTSFactory: { _, _ in mocks.mockOutgoingTTS },
        incomingTTSFactory: { _, _ in mocks.mockIncomingTTS },
        languagePairManager: mocks.languagePairManager,
        noticeClock: noticeClock
    )
}

private func transcript(_ text: String) -> TranscriptionResult {
    TranscriptionResult(text: text, confidence: 1, locale: Locale(identifier: "es-ES"), capturedAt: .now, audioDuration: 1)
}

/// Suspends until the calling task is cancelled (no polling, no real sleep).
private func suspendUntilCancelled() async {
    let gate = AsyncGate()
    await withTaskCancellationHandler { await gate.wait() } onCancel: { gate.open() }
}

@Suite("AudioCoordinator TTS", .serialized) @MainActor
struct AudioCoordinatorTTSTests {

    @Test("the voice clone warm-up starts with the session, never delays it, and stop cancels it (REQ-QS-31)")
    func voiceCloneWarmUpInBackground() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, noticeClock: TestClock())
        let locales = LockedArray<String>()
        let cancelled = LockedArray<Bool>()
        coordinator.voiceCloneWarmUp = { locale in
            locales.append(locale.identifier)
            await suspendUntilCancelled()
            cancelled.append(true)
        }

        await coordinator.start()   // returns while the warm-up still runs

        #expect(coordinator.isOutgoingActive)
        #expect(await waitUntil { locales.values.count == 1 })
        #expect(locales.values == [mocks.languagePairManager.targetLanguage.minimalIdentifier])
        #expect(cancelled.values.isEmpty)
        await coordinator.stop()
        #expect(await waitUntil { cancelled.values == [true] })
    }

    @Test("a failed capture start cancels the voice clone warm-up (REQ-QS-31)")
    func failedStartCancelsWarmUp() async {
        let mocks = CoordinatorMocks()
        mocks.mockAudioCapture.throwOnStartCapture = AudioError.permissionDenied
        let coordinator = makeCoordinator(mocks, noticeClock: TestClock())
        let started = LockedArray<Bool>()
        let cancelled = LockedArray<Bool>()
        coordinator.voiceCloneWarmUp = { _ in
            started.append(true)
            await suspendUntilCancelled()
            cancelled.append(true)
        }

        await coordinator.start()

        #expect(!coordinator.isOutgoingActive)
        #expect(await waitUntil { cancelled.values == [true] })
    }

    @Test("a superseded start (mic ended mid-start) cancels the voice clone warm-up (REQ-QS-31)")
    func supersededStartCancelsWarmUp() async {
        let mocks = CoordinatorMocks()
        let vadGate = AsyncGate()
        let coordinator = makeCoordinator(mocks, noticeClock: TestClock(), vadGate: vadGate)
        let cancelled = LockedArray<Bool>()
        coordinator.voiceCloneWarmUp = { _ in
            await suspendUntilCancelled()
            cancelled.append(true)
        }

        let starting = Task { await coordinator.start() }
        #expect(await waitUntil { vadGate.waiterCount == 1 })
        mocks.mockAudioCapture.stopCapture()   // the mic ends while start() is still coming up
        #expect(cancelled.values.isEmpty)
        vadGate.open()
        await starting.value

        #expect(!coordinator.isOutgoingActive)
        #expect(await waitUntil { cancelled.values == [true] })
    }

    @Test("outgoing sentences are queued: speak is never preceded by stopSpeaking (REQ-T-40, D-3)")
    func outgoingDoesNotInterrupt() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, noticeClock: TestClock())
        await coordinator.start()

        await mocks.mockOutgoingSTT.injectTranscription(transcript("hola"))
        await mocks.mockOutgoingSTT.injectTranscription(transcript("adiós"))

        #expect(await waitUntil { await mocks.mockOutgoingTTS.speakCalls.count == 2 })
        #expect(!(await mocks.mockOutgoingTTS.stopSpeakingCalled))
        await coordinator.stop()
    }

    @Test("incoming sentences are queued while incoming TTS speaks (REQ-T-43, D-7)")
    func incomingQueuesWhileSpeaking() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, noticeClock: TestClock())
        await coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { coordinator.isIncomingActive })
        coordinator.isIncomingSpeaking = true

        await mocks.mockIncomingSTT.injectTranscription(transcript("hello"))
        await mocks.mockIncomingSTT.injectTranscription(transcript("goodbye"))

        #expect(await waitUntil { await mocks.mockIncomingTTS.speakCalls.count == 2 })
        #expect(!(await mocks.mockIncomingTTS.stopSpeakingCalled))
        await coordinator.stop()
    }

    @Test("an incoming sentence is translated and spoken while outgoing TTS speaks (F8.5.3 REQ-H-11)")
    func incomingTranslatedWhileOutgoingSpeaks() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, noticeClock: TestClock())
        await coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { coordinator.isIncomingActive })
        coordinator.isOutgoingSpeaking = true

        await mocks.mockIncomingSTT.injectTranscription(transcript("hello"))

        #expect(await waitUntil { await mocks.mockIncomingTTS.speakCalls.count == 1 })
        #expect(await mocks.mockIncomingTTS.speakCalls.first?.text == "TRANSLATED: hello")
        await coordinator.stop()
    }

    @Test("an outgoing sentence is translated and spoken while incoming TTS speaks (F8.5.3 REQ-H-10)")
    func outgoingTranslatedWhileIncomingSpeaks() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, noticeClock: TestClock())
        await coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { coordinator.isIncomingActive })
        coordinator.isIncomingSpeaking = true

        await mocks.mockOutgoingSTT.injectTranscription(transcript("hola"))

        #expect(await waitUntil { await mocks.mockOutgoingTTS.speakCalls.count == 1 })
        #expect(await mocks.mockOutgoingTTS.speakCalls.first?.text == "TRANSLATED: hola")
        await coordinator.stop()
    }

    @Test("the one-shot mute turn still skips exactly one outgoing sentence")
    func muteTurnStillSkipsOne() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, noticeClock: TestClock())
        await coordinator.start()
        coordinator.suppressNextOutgoingTurn()

        await mocks.mockOutgoingSTT.injectTranscription(transcript("hola"))
        await mocks.mockOutgoingSTT.injectTranscription(transcript("adiós"))

        #expect(await waitUntil { await mocks.mockOutgoingTTS.speakCalls.count == 1 })
        #expect(await mocks.mockOutgoingTTS.speakCalls.map(\.text) == ["TRANSLATED: adiós"])
        await coordinator.stop()
    }

    @Test("a TTS event becomes the notice line, never an alert, and clears itself after 5 s (REQ-T-41)")
    func noticeAutoClears() async {
        let mocks = CoordinatorMocks()
        let clock = TestClock()
        let coordinator = makeCoordinator(mocks, noticeClock: clock)
        await coordinator.start()

        await mocks.mockOutgoingTTS.emit(.fellBack(from: .edgeTTS, to: .avSpeech))

        #expect(await waitUntil { coordinator.ttsNotice == "Edge TTS unavailable — used system voice" })
        #expect(coordinator.errorAlert == nil)
        #expect(await waitUntil { clock.pendingDeadlines == [.seconds(5)] })
        clock.advance(by: .seconds(5))
        #expect(await waitUntil { coordinator.ttsNotice == nil })
        await coordinator.stop()
    }

    @Test("a newer event replaces the notice and restarts its 5 s")
    func newerNoticeRestartsTimer() async {
        let mocks = CoordinatorMocks()
        let clock = TestClock()
        let coordinator = makeCoordinator(mocks, noticeClock: clock)
        await coordinator.start()

        await mocks.mockOutgoingTTS.emit(.backlog(pending: 20))
        #expect(await waitUntil { coordinator.ttsNotice == "Translation running behind — 20 sentences waiting" })
        clock.advance(by: .seconds(4))
        await mocks.mockOutgoingTTS.emit(.utteranceSkipped(.timeout))
        #expect(await waitUntil { coordinator.ttsNotice == "Speech failed — sentence skipped" })
        #expect(await waitUntil { clock.pendingDeadlines == [.seconds(9)] })
        clock.advance(by: .seconds(4))
        #expect(coordinator.ttsNotice == "Speech failed — sentence skipped")
        clock.advance(by: .seconds(1))
        #expect(await waitUntil { coordinator.ttsNotice == nil })
        await coordinator.stop()
    }

    @Test("stop() clears the notice")
    func stopClearsNotice() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, noticeClock: TestClock())
        await coordinator.start()
        await mocks.mockOutgoingTTS.emit(.utteranceSkipped(.noVoice))
        #expect(await waitUntil { coordinator.ttsNotice != nil })
        await coordinator.stop()
        #expect(coordinator.ttsNotice == nil)
    }
}

@Suite("TTS notice texts")
struct TTSNoticeTextTests {
    @Test("each event has the design §3.7 text")
    func texts() {
        #expect(TTSEvent.fellBack(from: .edgeTTS, to: .avSpeech).noticeText(language: "Ukrainian")
                == "Edge TTS unavailable — used system voice")
        #expect(TTSEvent.fellBack(from: .kokoro, to: .avSpeech).noticeText(language: "English")
                == "Kokoro unavailable — used system voice")
        #expect(TTSEvent.utteranceSkipped(.noVoice).noticeText(language: "Ukrainian")
                == "No voice for Ukrainian — sentence skipped")
        #expect(TTSEvent.utteranceSkipped(.timeout).noticeText(language: "x") == "Speech failed — sentence skipped")
        #expect(TTSEvent.utteranceSkipped(.primaryFailed("boom")).noticeText(language: "x")
                == "Speech failed — sentence skipped")
        #expect(TTSEvent.backlog(pending: 20).noticeText(language: "x")
                == "Translation running behind — 20 sentences waiting")
        #expect(!TTSEvent.utteranceSkipped(.interrupted).noticeText(language: "x").isEmpty)
        #expect(!TTSEvent.utteranceSkipped(.outputUnavailable).noticeText(language: "x").isEmpty)
    }
}

@Suite("Voice preview during a session") @MainActor
struct VoicePreviewSessionTests {
    @Test("previews are disabled while a session runs or starts (REQ-T-33)")
    func disabledDuringSession() {
        #expect(VoicePreviewSection.canPreview(isPlaying: false, isSessionActive: false))
        #expect(!VoicePreviewSection.canPreview(isPlaying: false, isSessionActive: true))
        #expect(!VoicePreviewSection.canPreview(isPlaying: true, isSessionActive: false))
        #expect(VoicePreviewSection.sessionActiveHelp.contains("session"))
    }
}
