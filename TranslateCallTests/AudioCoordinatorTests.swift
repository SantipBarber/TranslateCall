@_exported import Testing
import AVFoundation
@testable import TranslateCall

// MARK: - Helpers

private let callTarget = CaptureTarget.app(bundleID: "com.test.call")

/// All mocks for a single coordinator test scenario.
@MainActor
struct CoordinatorMocks {
    let mockAudioCapture = MockAudioCapture()
    let mockSystemCapture = MockSystemAudioCapture()
    // Outgoing VAD (named mockVADFactory to match design doc naming)
    let mockVADFactory = MockVADService()
    let mockIncomingVAD = MockVADService()
    let mockOutgoingSTT = MockSpeechRecognizerService()
    let mockIncomingSTT = MockSpeechRecognizerService()
    let mockOutgoingTTS = MockSynthesisService()
    let mockIncomingTTS = MockSynthesisService()
    let mockOutgoingTranslation = MockTranslationService()
    let mockIncomingTranslation = MockTranslationService()
    /// No language loader: the manager must not re-resolve its pair in the background while a test runs
    /// (the race made `updateLanguagePairReconfigures` flaky once `start()` gained the pack check, F8.5.4).
    let languagePairManager = LanguagePairManager(languageLoader: { [] })
}

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
        languagePairManager: mocks.languagePairManager
    )
}

// MARK: - Tests

@Suite("AudioCoordinator", .serialized) @MainActor
struct AudioCoordinatorTests {

    @Test("start() activates outgoing pipeline")
    func startActivatesOutgoing() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)

        await coordinator.start()

        #expect(mocks.mockAudioCapture.startCaptureCalled)
        #expect(await mocks.mockVADFactory.activateCalled)
        #expect(await mocks.mockOutgoingSTT.activateCalled)
        #expect(coordinator.isOutgoingActive)
        #expect(!coordinator.isStarting)
    }

    @Test("start() without a capture app runs outgoing only")
    func startWithoutCaptureAppSkipsIncoming() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)

        await coordinator.start()

        #expect(coordinator.isOutgoingActive)
        #expect(!coordinator.isIncomingActive)
        #expect(!(await mocks.mockSystemCapture.activateCalled))
    }

    @Test("start() also activates incoming pipeline by default")
    func startActivatesIncoming() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)

        await coordinator.start(captureTarget: callTarget)

        #expect(await mocks.mockSystemCapture.activateCalled)
        #expect(await mocks.mockIncomingVAD.activateCalled)
        #expect(await mocks.mockIncomingSTT.activateCalled)
        #expect(coordinator.isIncomingActive)
    }

    @Test("start() skips incoming pipeline when system capture activation fails")
    func startSkipsIncomingOnPermissionDenied() async {
        let mocks = CoordinatorMocks()
        await mocks.mockSystemCapture.setThrowOnActivate(SystemAudioCaptureError.permissionDenied)
        let coordinator = makeCoordinator(mocks)

        await coordinator.start(captureTarget: callTarget)

        #expect(coordinator.isOutgoingActive)
        #expect(!coordinator.isIncomingActive)
        #expect(coordinator.errorAlert != nil)
        #expect(coordinator.incomingStatus == .stopped(.permissionDenied))
    }

    @Test("stop() deactivates all services and resets active flags")
    func stopDeactivatesAll() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)

        await coordinator.start(captureTarget: callTarget)
        await coordinator.stop()

        #expect(await mocks.mockOutgoingSTT.deactivateCalled)
        #expect(await mocks.mockIncomingSTT.deactivateCalled)
        #expect(await mocks.mockOutgoingTTS.deactivateCalled)
        #expect(await mocks.mockIncomingTTS.deactivateCalled)
        #expect(mocks.mockAudioCapture.stopCaptureCalled)
        #expect(!coordinator.isOutgoingActive)
        #expect(!coordinator.isIncomingActive)
    }

    @Test("updateLanguagePair() calls setLocale on both STT services")
    func updateLanguagePairReconfigures() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)

        await mocks.languagePairManager.swapLanguages()
        await coordinator.updateLanguagePair()

        // Both STT services should have received a setLocale call after the swap.
        let outgoingCalls = await mocks.mockOutgoingSTT.setLocaleCalls
        let incomingCalls = await mocks.mockIncomingSTT.setLocaleCalls
        #expect(!outgoingCalls.isEmpty)
        #expect(!incomingCalls.isEmpty)

        // Outgoing should use source language, incoming should use target language.
        let expectedSource = Locale(identifier: mocks.languagePairManager.sourceLanguage.minimalIdentifier)
        let expectedTarget = Locale(identifier: mocks.languagePairManager.targetLanguage.minimalIdentifier)
        #expect(outgoingCalls.last == expectedSource)
        #expect(incomingCalls.last == expectedTarget)
    }

    @Test("start() with fatal audio capture error sets errorAlert and leaves both pipelines inactive")
    func fatalAudioErrorStopsBothPipelines() async {
        let mocks = CoordinatorMocks()
        mocks.mockAudioCapture.throwOnStartCapture = AudioError.permissionDenied
        let coordinator = makeCoordinator(mocks)

        await coordinator.start()

        #expect(!coordinator.isOutgoingActive)
        #expect(!coordinator.isIncomingActive)
        #expect(coordinator.errorAlert != nil)
        // Error alert should mention microphone
        let title = coordinator.errorAlert?.title ?? ""
        #expect(title.localizedCaseInsensitiveContains("Microphone") || title.localizedCaseInsensitiveContains("Access"))
    }

    @Test("non-fatal outgoing STT error still allows incoming pipeline to activate")
    func nonFatalOutgoingSTTErrorKeepsIncomingAlive() async {
        let mocks = CoordinatorMocks()
        await mocks.mockOutgoingSTT.setThrowOnActivate(STTError.permissionDenied)
        let coordinator = makeCoordinator(mocks)

        await coordinator.start(captureTarget: callTarget)

        // Outgoing is still active (audio capture + VAD succeeded)
        #expect(coordinator.isOutgoingActive)
        // Incoming pipeline should have started despite outgoing STT failure
        #expect(coordinator.isIncomingActive)
        // Error alert was set for the STT failure
        #expect(coordinator.errorAlert != nil)
    }

    @Test("start() is idempotent — second call while active is a no-op")
    func startIsIdempotent() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)

        await coordinator.start()
        await coordinator.start()  // should be a no-op
        #expect(mocks.mockAudioCapture.startCount == 1)
    }

    @Test("Stop → Start hands the incoming VAD a fresh, live stream (A1)")
    func restartGivesFreshIncomingStream() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)

        await coordinator.start(captureTarget: callTarget)
        await coordinator.stop()
        await coordinator.start(captureTarget: callTarget)
        await mocks.mockSystemCapture.injectBuffer(makePCMBuffer())

        #expect(await waitUntil { await mocks.mockIncomingVAD.receivedBufferCount == 1 })
        #expect(await mocks.mockSystemCapture.activatedTargets == [callTarget, callTarget])
        #expect(coordinator.isIncomingActive)
    }

    @Test("Stop → Start hands the outgoing VAD a fresh, live mic stream")
    func restartGivesFreshMicStream() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)

        await coordinator.start()
        await coordinator.stop()
        await coordinator.start()
        mocks.mockAudioCapture.injectBuffer(makePCMBuffer())

        #expect(await waitUntil { await mocks.mockVADFactory.receivedBufferCount == 1 })
        #expect(mocks.mockAudioCapture.startCount == 2)
    }

    @Test("start() passes the capture target to system capture")
    func startPassesCaptureTarget() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        #expect(await mocks.mockSystemCapture.activatedTargets == [callTarget])
    }

    @Test("no capture target → incoming .disabled and system capture untouched")
    func noTargetDisablesIncoming() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()
        #expect(coordinator.incomingStatus == .disabled)
        #expect(!(await mocks.mockSystemCapture.activateCalled))
    }

    @Test("target app not running → .stopped(.targetNotFound), outgoing keeps running, no alert")
    func targetNotFoundStops() async {
        let mocks = CoordinatorMocks()
        await mocks.mockSystemCapture.setThrowOnActivate(SystemAudioCaptureError.targetNotFound(bundleID: "com.test.call"))
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        #expect(coordinator.incomingStatus == .stopped(.targetNotFound(bundleID: "com.test.call")))
        #expect(coordinator.isOutgoingActive)
        #expect(!coordinator.isIncomingActive)
        #expect(coordinator.errorAlert == nil)
    }

    @Test("stream stops mid-session → incoming torn down, .stopped, outgoing alive, speaking released")
    func streamStopTearsDownIncoming() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        coordinator.isIncomingSpeaking = true

        await mocks.mockSystemCapture.emit(.stopped(.streamError("boom")))

        #expect(await waitUntil { coordinator.incomingStatus == .stopped(.streamError("boom")) })
        #expect(await mocks.mockIncomingVAD.deactivateCalled)
        #expect(await mocks.mockIncomingSTT.deactivateCalled)
        #expect(await mocks.mockIncomingTTS.deactivateCalled)
        #expect(!coordinator.isIncomingSpeaking)
        #expect(coordinator.isOutgoingActive)
    }

    @Test("Retry after a stop reactivates incoming with a fresh stream")
    func retryReactivates() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        await mocks.mockSystemCapture.emit(.stopped(.streamError("boom")))
        #expect(await waitUntil { coordinator.incomingStatus == .stopped(.streamError("boom")) })

        coordinator.retryIncoming(captureTarget: callTarget)

        #expect(await waitUntil { coordinator.incomingStatus == .active })
        await mocks.mockSystemCapture.injectBuffer(makePCMBuffer())
        #expect(await waitUntil { await mocks.mockIncomingVAD.receivedBufferCount == 1 })
        #expect(await mocks.mockSystemCapture.activatedTargets.count == 2)
    }

    @Test("Retry twice in a row activates once")
    func doubleRetryActivatesOnce() async {
        let mocks = CoordinatorMocks()
        await mocks.mockSystemCapture.setThrowOnActivate(SystemAudioCaptureError.targetNotFound(bundleID: "com.test.call"))
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        await mocks.mockSystemCapture.setThrowOnActivate(nil)

        coordinator.retryIncoming(captureTarget: callTarget)
        coordinator.retryIncoming(captureTarget: callTarget)

        #expect(await waitUntil { coordinator.incomingStatus == .active })
        #expect(await mocks.mockSystemCapture.activatedTargets.count == 1)
    }

    @Test("Retry is a no-op unless incoming is stopped")
    func retryOnlyWhenStopped() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        coordinator.retryIncoming(captureTarget: callTarget)
        #expect(coordinator.incomingStatus == .active)
        #expect(await mocks.mockSystemCapture.activatedTargets.count == 1)
    }

    @Test("Retry uses the capture target it is given, not the one start() saw")
    func retryWithNewTargetActivatesIt() async {
        let mocks = CoordinatorMocks()
        await mocks.mockSystemCapture.setThrowOnActivate(SystemAudioCaptureError.targetNotFound(bundleID: "com.test.call"))
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        await mocks.mockSystemCapture.setThrowOnActivate(nil)
        let otherTarget = CaptureTarget.app(bundleID: "com.test.other")

        coordinator.retryIncoming(captureTarget: otherTarget)

        #expect(await waitUntil { coordinator.incomingStatus == .active })
        #expect(await mocks.mockSystemCapture.activatedTargets == [otherTarget])
    }

    @Test("Retry from .disabled activates once a capture target exists")
    func retryFromDisabledWithTargetActivates() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()
        #expect(coordinator.incomingStatus == .disabled)

        coordinator.retryIncoming(captureTarget: nil)
        #expect(coordinator.incomingStatus == .disabled)
        coordinator.retryIncoming(captureTarget: callTarget)

        #expect(await waitUntil { coordinator.incomingStatus == .active })
        #expect(await mocks.mockSystemCapture.activatedTargets == [callTarget])
    }

    @Test("Retry is a no-op when no session is running")
    func retryWithoutSessionIsNoOp() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        coordinator.retryIncoming(captureTarget: callTarget)
        #expect(coordinator.incomingStatus == .idle)
        #expect(!(await mocks.mockSystemCapture.activateCalled))
    }

    @Test("stop() during an in-flight activation leaves nothing alive and ends .idle")
    func stopDuringActivationTearsDown() async {
        let mocks = CoordinatorMocks()
        await mocks.mockSystemCapture.holdNextActivation()
        let coordinator = makeCoordinator(mocks)

        let starting = Task { await coordinator.start(captureTarget: callTarget) }
        #expect(await waitUntil { await mocks.mockSystemCapture.isWaitingAtGate })
        let stopping = Task { await coordinator.stop() }
        await mocks.mockSystemCapture.releaseActivation()
        await starting.value
        await stopping.value

        #expect(coordinator.incomingStatus == .idle)
        #expect(await mocks.mockIncomingVAD.activateCount == 0)
        #expect(await mocks.mockSystemCapture.deactivateCalled)
        #expect(!coordinator.isOutgoingActive)
    }

    @Test("stream stop while incoming is still starting ends .stopped, not .active")
    func stopEventDuringStartingEndsStopped() async {
        let mocks = CoordinatorMocks()
        await mocks.mockSystemCapture.holdNextActivation()
        let coordinator = makeCoordinator(mocks)

        let starting = Task { await coordinator.start(captureTarget: callTarget) }
        #expect(await waitUntil { await mocks.mockSystemCapture.isWaitingAtGate })
        #expect(await waitUntil { coordinator.incomingStatus == .starting })
        await mocks.mockSystemCapture.emit(.stopped(.streamError("died")))
        #expect(await waitUntil { coordinator.pendingStopReasonForTesting != nil })
        await mocks.mockSystemCapture.releaseActivation()
        await starting.value

        #expect(coordinator.incomingStatus == .stopped(.streamError("died")))
        #expect(!coordinator.isIncomingActive)
    }

    @Test("Retry during an in-flight stop() is a no-op; stop ends .idle with nothing alive")
    func retryDuringStopIsNoOp() async {
        let mocks = CoordinatorMocks()
        await mocks.mockSystemCapture.setThrowOnActivate(SystemAudioCaptureError.targetNotFound(bundleID: "com.test.call"))
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        #expect(coordinator.incomingStatus == .stopped(.targetNotFound(bundleID: "com.test.call")))
        await mocks.mockSystemCapture.setThrowOnActivate(nil)
        await mocks.mockSystemCapture.holdNextDeactivation()

        let stopping = Task { await coordinator.stop() }
        #expect(await waitUntil { await mocks.mockSystemCapture.isWaitingAtDeactivateGate })
        coordinator.retryIncoming(captureTarget: callTarget)
        #expect(coordinator.incomingStatus != .starting)
        await mocks.mockSystemCapture.releaseDeactivation()
        await stopping.value

        #expect(coordinator.incomingStatus == .idle)
        #expect(!coordinator.isOutgoingActive)
        #expect(await mocks.mockSystemCapture.activatedTargets.isEmpty)
        #expect(await mocks.mockIncomingVAD.activateCount == 0)
    }

    @Test("a stream-stop event that lands during stop() is ignored; stop ends .idle")
    func streamStopDuringStopIsIgnored() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        await mocks.mockSystemCapture.holdNextDeactivation()

        let stopping = Task { await coordinator.stop() }
        #expect(await waitUntil { await mocks.mockSystemCapture.isWaitingAtDeactivateGate })
        await coordinator.handleIncomingEvent(.stopped(.streamError("late")))
        #expect(coordinator.incomingStatus != .stopped(.streamError("late")))   // no stale banner
        await mocks.mockSystemCapture.releaseDeactivation()
        await stopping.value

        #expect(coordinator.incomingStatus == .idle)
    }

    @Test("stop() resets incoming status to .idle")
    func stopResetsStatus() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        await coordinator.stop()
        #expect(coordinator.incomingStatus == .idle)
        #expect(!coordinator.isIncomingActive)
    }

    @Test("stop() while start() is still bringing up outgoing ends with nothing alive (M-4)")
    func stopDuringOutgoingStartSupersedesStart() async {
        let mocks = CoordinatorMocks()
        await mocks.mockVADFactory.holdNextActivation()
        let coordinator = makeCoordinator(mocks)

        let starting = Task { await coordinator.start(captureTarget: callTarget) }
        #expect(await waitUntil { await mocks.mockVADFactory.isWaitingAtGate })
        await coordinator.stop()
        await mocks.mockVADFactory.releaseActivation()
        await starting.value

        #expect(!coordinator.isOutgoingActive)
        #expect(!coordinator.isStarting)
        #expect(coordinator.incomingStatus == .idle)
        #expect(!(await mocks.mockSystemCapture.activateCalled))
        #expect(!mocks.mockAudioCapture.isCapturing)
        #expect(await mocks.mockOutgoingSTT.deactivateCalled)   // created after stop(), released by start()
        #expect(await mocks.mockOutgoingTTS.deactivateCalled)
    }

    @Test("a second start() while starting is a no-op and isStarting stays true until the first ends")
    func secondStartWhileStartingIsNoOp() async {
        let mocks = CoordinatorMocks()
        await mocks.mockVADFactory.holdNextActivation()
        let coordinator = makeCoordinator(mocks)

        let first = Task { await coordinator.start(captureTarget: callTarget) }
        #expect(await waitUntil { await mocks.mockVADFactory.isWaitingAtGate })
        await coordinator.start(captureTarget: callTarget)

        #expect(coordinator.isStarting)
        #expect(mocks.mockAudioCapture.startCount == 1)
        await mocks.mockVADFactory.releaseActivation()
        await first.value
        #expect(!coordinator.isStarting)
        #expect(coordinator.isOutgoingActive)
        #expect(coordinator.incomingStatus == .active)
        #expect(await mocks.mockVADFactory.activateCount == 1)
    }

    @Test("the mic dying while start() is still running ends the session instead of going active")
    func micEndedDuringStartAbortsStart() async {
        let mocks = CoordinatorMocks()
        await mocks.mockVADFactory.holdNextActivation()
        let coordinator = makeCoordinator(mocks)

        let starting = Task { await coordinator.start(captureTarget: callTarget) }
        #expect(await waitUntil { await mocks.mockVADFactory.isWaitingAtGate })
        mocks.mockAudioCapture.stopCapture()   // AudioManager stopped the mic on its own
        await mocks.mockVADFactory.releaseActivation()
        await starting.value

        #expect(!coordinator.isOutgoingActive)
        #expect(!coordinator.isStarting)
        #expect(!(await mocks.mockSystemCapture.activateCalled))
        #expect(await mocks.mockOutgoingSTT.deactivateCalled)
    }

    @Test("capture ended by AudioManager stops the whole session")
    func outgoingCaptureEndedStopsSession() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        #expect(coordinator.isOutgoingActive)

        await coordinator.handleOutgoingCaptureEnded()

        #expect(!coordinator.isOutgoingActive)
        #expect(coordinator.incomingStatus == .idle)
        #expect(await mocks.mockSystemCapture.deactivateCount == 1)
    }

    @Test("capture ended during an in-flight stop() does not run a second teardown")
    func outgoingCaptureEndedDuringStopIsNoOp() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: callTarget)
        await mocks.mockSystemCapture.holdNextDeactivation()

        let stopping = Task { await coordinator.stop() }
        #expect(await waitUntil { await mocks.mockSystemCapture.isWaitingAtDeactivateGate })
        await coordinator.handleOutgoingCaptureEnded()
        await mocks.mockSystemCapture.releaseDeactivation()
        await stopping.value

        #expect(await mocks.mockSystemCapture.deactivateCount == 1)
        #expect(!coordinator.isOutgoingActive)
        #expect(coordinator.incomingStatus == .idle)
    }
}

// MARK: - MockSystemAudioCapture helper

// Add a mutating helper to set throwOnActivate from @MainActor context.
// MockSystemAudioCapture is an actor, so we must use await to set its properties.
extension MockSystemAudioCapture {
    func setThrowOnActivate(_ error: Error?) {
        throwOnActivate = error
    }
}

extension MockSpeechRecognizerService {
    func setThrowOnActivate(_ error: Error?) {
        throwOnActivate = error
    }
}
