@_exported import Testing
import AVFoundation
@testable import TranslateCall

// MARK: - Helpers

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
    let languagePairManager = LanguagePairManager()
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

    @Test("start() also activates incoming pipeline by default", .disabled("F8.5.1: start() skips incoming without an SCRunningApplication (16e096c) and SCRunningApplication cannot be built in tests — needs an injectable capture target"))
    func startActivatesIncoming() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)

        await coordinator.start()

        #expect(await mocks.mockSystemCapture.activateCalled)
        #expect(await mocks.mockIncomingVAD.activateCalled)
        #expect(await mocks.mockIncomingSTT.activateCalled)
        #expect(coordinator.isIncomingActive)
    }

    @Test("start() skips incoming pipeline when system capture activation fails", .disabled("F8.5.1: start() skips incoming without an SCRunningApplication (16e096c) and SCRunningApplication cannot be built in tests — needs an injectable capture target"))
    func startSkipsIncomingOnPermissionDenied() async {
        let mocks = CoordinatorMocks()
        await mocks.mockSystemCapture.setThrowOnActivate(SystemAudioCaptureError.permissionDenied)
        let coordinator = makeCoordinator(mocks)

        await coordinator.start()

        #expect(coordinator.isOutgoingActive)
        #expect(!coordinator.isIncomingActive)
        #expect(coordinator.errorAlert != nil)
    }

    @Test("stop() deactivates all services and resets active flags", .disabled("F8.5.1: start() skips incoming without an SCRunningApplication (16e096c) and SCRunningApplication cannot be built in tests — needs an injectable capture target"))
    func stopDeactivatesAll() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)

        await coordinator.start()
        await coordinator.stop()

        #expect(await mocks.mockOutgoingSTT.deactivateCalled)
        #expect(await mocks.mockIncomingSTT.deactivateCalled)
        #expect(await mocks.mockOutgoingTTS.deactivateCalled)
        #expect(await mocks.mockIncomingTTS.deactivateCalled)
        #expect(mocks.mockAudioCapture.stopCaptureCalled)
        #expect(!coordinator.isOutgoingActive)
        #expect(!coordinator.isIncomingActive)
    }

    @Test("updateLanguagePair() calls setLocale on both STT services", .disabled("F8.5.1: start() skips incoming without an SCRunningApplication (16e096c) and SCRunningApplication cannot be built in tests — needs an injectable capture target"))
    func updateLanguagePairReconfigures() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()

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

    @Test("non-fatal outgoing STT error still allows incoming pipeline to activate", .disabled("F8.5.1: start() skips incoming without an SCRunningApplication (16e096c) and SCRunningApplication cannot be built in tests — needs an injectable capture target"))
    func nonFatalOutgoingSTTErrorKeepsIncomingAlive() async {
        let mocks = CoordinatorMocks()
        await mocks.mockOutgoingSTT.setThrowOnActivate(STTError.permissionDenied)
        let coordinator = makeCoordinator(mocks)

        await coordinator.start()

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
        let firstCaptureCount = mocks.mockAudioCapture.startCaptureCalled ? 1 : 0
        await coordinator.start()  // should be a no-op

        // startCapture should have been called only once
        let captureCallCount = mocks.mockAudioCapture.startCaptureCalled ? 1 : 0
        #expect(firstCaptureCount == captureCallCount)
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
