import Foundation
import Testing
@testable import TranslateCall

@MainActor
private func makeCoordinator(_ mocks: CoordinatorMocks, noticeClock: TestClock) -> AudioCoordinator {
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
        noticeClock: noticeClock
    )
}

private func transcript(_ text: String) -> TranscriptionResult {
    TranscriptionResult(text: text, confidence: 1, locale: Locale(identifier: "es-ES"), capturedAt: .now, audioDuration: 1)
}

@Suite("AudioCoordinator TTS", .serialized) @MainActor
struct AudioCoordinatorTTSTests {

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

    @Test("incoming sentences are still dropped while incomingCaptureSuppressed is true (REQ-T-43)")
    func incomingDroppedWhileSuppressed() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, noticeClock: TestClock())
        await coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { coordinator.isIncomingActive })
        coordinator.suppressIncomingPipeline(true)

        await mocks.mockIncomingSTT.injectTranscription(transcript("hello"))

        // Negative check: bounded wait; the suppressed sentence must never reach incoming TTS.
        #expect(!(await waitUntil(timeout: .milliseconds(300)) {
            await !mocks.mockIncomingTTS.speakCalls.isEmpty
        }))

        // Control: the same path speaks once suppression lifts, so the drop above was the guard.
        coordinator.suppressIncomingPipeline(false)
        await mocks.mockIncomingSTT.injectTranscription(transcript("goodbye"))
        #expect(await waitUntil { await mocks.mockIncomingTTS.speakCalls.count == 1 })
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
