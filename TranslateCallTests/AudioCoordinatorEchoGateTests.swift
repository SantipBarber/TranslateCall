import AVFoundation
import Testing
@testable import TranslateCall

private let callTarget = CaptureTarget.app(bundleID: "com.test.call")

@MainActor
private func makeCoordinator(_ mocks: CoordinatorMocks, gateClock: TestClock) -> AudioCoordinator {
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
        echoGateClock: gateClock
    )
}

/// Feeds one loud mic buffer and waits until the outgoing VAD has seen it; returns its peak there.
@MainActor
private func micPeakAtVAD(_ mocks: CoordinatorMocks) async -> Float? {
    let before = await mocks.mockVADFactory.receivedPeaks.count
    mocks.mockAudioCapture.injectBuffer(makePCMBuffer(frames: 160, fill: 0.5))
    guard await waitUntil({ await mocks.mockVADFactory.receivedPeaks.count == before + 1 }) else { return nil }
    return await mocks.mockVADFactory.receivedPeaks.last
}

@Suite("AudioCoordinator mic echo gate (F8.5.3)", .serialized) @MainActor
struct AudioCoordinatorEchoGateTests {

    @Test("headphones (default): the mic reaches the VAD while the remote translation plays")
    func headphonesNeverMutes() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, gateClock: TestClock())
        await coordinator.start(captureTarget: callTarget)
        coordinator.isIncomingSpeaking = true

        #expect(await micPeakAtVAD(mocks) == 0.5)
        #expect(coordinator.conversationState == .speaking)
        await coordinator.stop()
    }

    @Test("speakers: the mic is silenced while incoming speaks and for 300 ms after (REQ-H-03, A6)")
    func speakersModeGatesOutgoingVADInput() async {
        let mocks = CoordinatorMocks()
        let clock = TestClock()
        let coordinator = makeCoordinator(mocks, gateClock: clock)
        coordinator.listeningMode = .speakers
        await coordinator.start(captureTarget: callTarget)

        coordinator.isIncomingSpeaking = true
        #expect(await micPeakAtVAD(mocks) == 0)
        #expect(await waitUntil { coordinator.conversationState == .micPaused })

        coordinator.isIncomingSpeaking = false
        #expect(await micPeakAtVAD(mocks) == 0, "still inside the 300 ms tail")
        clock.advance(by: .milliseconds(300))
        #expect(await micPeakAtVAD(mocks) == 0.5)
        #expect(await waitUntil { coordinator.conversationState == .listening })
        await coordinator.stop()
    }

    @Test("Review focus: turning speakers mode off mid-sentence reopens the mic at once (REQ-H-05)")
    func listeningModeAppliesLive() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, gateClock: TestClock())
        coordinator.listeningMode = .speakers
        await coordinator.start(captureTarget: callTarget)
        coordinator.isIncomingSpeaking = true
        #expect(await micPeakAtVAD(mocks) == 0)

        coordinator.listeningMode = .headphones

        #expect(await waitUntil { coordinator.conversationState == .speaking })
        #expect(await micPeakAtVAD(mocks) == 0.5)
        await coordinator.stop()
    }

    @Test("Review focus: the call app stops while its translation plays → mic reopens, no tail (REQ-H-06)")
    func gateResetOnIncomingStop() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, gateClock: TestClock())
        coordinator.listeningMode = .speakers
        await coordinator.start(captureTarget: callTarget)
        coordinator.isIncomingSpeaking = true
        #expect(await micPeakAtVAD(mocks) == 0)

        await mocks.mockSystemCapture.emit(.stopped(.streamError("gone")))

        #expect(await waitUntil { coordinator.incomingStatus == .stopped(.streamError("gone")) })
        #expect(await micPeakAtVAD(mocks) == 0.5)
        #expect(await waitUntil { coordinator.conversationState == .listening })
        await coordinator.stop()
    }

    @Test("an abandoned incoming activation reopens the mic (REQ-H-06, design §3.2)")
    func abandonedIncomingActivationReopensGate() async {
        let mocks = CoordinatorMocks()
        await mocks.mockSystemCapture.holdNextActivation()
        let coordinator = makeCoordinator(mocks, gateClock: TestClock())
        coordinator.listeningMode = .speakers

        let starting = Task { await coordinator.start(captureTarget: callTarget) }
        #expect(await waitUntil { await mocks.mockSystemCapture.isWaitingAtGate })
        coordinator.isIncomingSpeaking = true
        #expect(await micPeakAtVAD(mocks) == 0)
        await mocks.mockSystemCapture.emit(.stopped(.streamError("died")))
        #expect(await waitUntil { coordinator.pendingStopReasonForTesting != nil })
        await mocks.mockSystemCapture.releaseActivation()
        await starting.value

        #expect(coordinator.incomingStatus == .stopped(.streamError("died")))
        #expect(!coordinator.isIncomingSpeaking)
        #expect(await micPeakAtVAD(mocks) == 0.5)
        #expect(await waitUntil { !coordinator.isMicPaused && coordinator.conversationState == .listening })
        await coordinator.stop()
    }

    @Test("stop() leaves the conversation .listening and the mic unpaused")
    func stopResetsConversationState() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, gateClock: TestClock())
        coordinator.listeningMode = .speakers
        await coordinator.start(captureTarget: callTarget)
        coordinator.isIncomingSpeaking = true
        #expect(await micPeakAtVAD(mocks) == 0)
        #expect(await waitUntil { coordinator.conversationState == .micPaused })

        await coordinator.stop()

        #expect(!coordinator.isMicPaused)
        #expect(coordinator.conversationState == .listening)
        #expect(coordinator.micEchoGate == nil)
    }

    @Test("a start that fails on the mic leaves no gate behind")
    func failedStartReleasesGate() async {
        let mocks = CoordinatorMocks()
        mocks.mockAudioCapture.throwOnStartCapture = AudioError.permissionDenied
        let coordinator = makeCoordinator(mocks, gateClock: TestClock())

        await coordinator.start(captureTarget: callTarget)

        #expect(coordinator.micEchoGate == nil)
    }

    @Test("R1: a late advisory pause report after the mic reopened does not leave it paused")
    func latePauseReportReReadsGate() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks, gateClock: TestClock())
        coordinator.listeningMode = .speakers
        await coordinator.start(captureTarget: callTarget)
        coordinator.isIncomingSpeaking = true
        #expect(await micPeakAtVAD(mocks) == 0)
        #expect(await waitUntil { coordinator.isMicPaused })

        coordinator.listeningMode = .headphones
        #expect(await waitUntil { !coordinator.isMicPaused })
        // The gate's "paused" report from the muted buffer lands only now (separate MainActor hop).
        coordinator.syncMicPausedFromGate(generation: coordinator.sessionGeneration)

        #expect(coordinator.micEchoGate?.isMicPaused == false)
        #expect(!coordinator.isMicPaused)
        #expect(coordinator.conversationState == .speaking)
        await coordinator.stop()
    }
}

@Suite("Conversation state presentation")
struct ConversationStatePresentationTests {
    @Test("badge label and icon per state (REQ-H-13)")
    func badge() {
        let idle = StatusBadgeView.presentation(isCapturing: false, isSpeechActive: false, state: .speaking)
        #expect(idle.label == "Idle")
        #expect(StatusBadgeView.presentation(isCapturing: true, isSpeechActive: true, state: .listening).label
                == "Speech detected")
        #expect(StatusBadgeView.presentation(isCapturing: true, isSpeechActive: false, state: .speaking).label
                == "Speaking translation")
        let paused = StatusBadgeView.presentation(isCapturing: true, isSpeechActive: false, state: .micPaused)
        #expect(paused.label == "Mic paused (speakers)")
        #expect(paused.icon == "mic.slash")
    }

    @Test("menu bar icon per state")
    func menuBarIcon() {
        #expect(MenuBarController.iconName(state: .listening, isCapturing: false) == "mic.slash")
        #expect(MenuBarController.iconName(state: .listening, isCapturing: true) == "mic")
        #expect(MenuBarController.iconName(state: .speaking, isCapturing: true) == "waveform")
        #expect(MenuBarController.iconName(state: .micPaused, isCapturing: true) == "mic.slash.circle")
    }
}
