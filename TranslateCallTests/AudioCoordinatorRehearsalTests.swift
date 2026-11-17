import AVFoundation
import Combine
import Foundation
import Testing
@testable import TranslateCall

// MARK: - Helpers

/// The same mock-backed coordinator shape used by `AudioCoordinatorTests.swift`.
@MainActor
struct RehearsalCoordinatorMocks {
    let mockAudioCapture = MockAudioCapture()
    let mockSystemCapture = MockSystemAudioCapture()
    let mockVADFactory = MockVADService()
    let mockIncomingVAD = MockVADService()
    let mockOutgoingSTT = MockSpeechRecognizerService()
    let mockIncomingSTT = MockSpeechRecognizerService()
    let mockOutgoingTTS = MockSynthesisService()
    let mockIncomingTTS = MockSynthesisService()
    let mockOutgoingTranslation = MockTranslationService()
    let mockIncomingTranslation = MockTranslationService()
    let languagePairManager = LanguagePairManager(languageLoader: { [] })
}

@MainActor
private func makeRehearsalCoordinator(
    _ mocks: RehearsalCoordinatorMocks,
    isTranslationPairInstalled: @escaping (Locale.Language, Locale.Language) async -> Bool = { _, _ in true }
) -> AudioCoordinator {
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
        isTranslationPairInstalled: isTranslationPairInstalled
    )
}

// MARK: - Tests

@Suite("AudioCoordinator rehearsal (REQ-FR-56)", .serialized) @MainActor
struct AudioCoordinatorRehearsalTests {

    @Test("rehearsal ignores the capture target and runs outgoing only")
    func rehearsalIgnoresCaptureTarget() async {
        let mocks = RehearsalCoordinatorMocks()
        let coordinator = makeRehearsalCoordinator(mocks)

        await coordinator.start(captureTarget: .app(bundleID: "com.test.call"), rehearsal: true)

        #expect(coordinator.isOutgoingActive)
        #expect(!(await mocks.mockSystemCapture.activateCalled))
        #expect(coordinator.isRehearsal)
    }

    @Test("isRehearsal is already true when isStarting first becomes true")
    func isRehearsalBeforeStarting() async {
        let mocks = RehearsalCoordinatorMocks()
        let coordinator = makeRehearsalCoordinator(mocks)
        var seen: Bool?
        let sink = coordinator.$isStarting
            .filter { $0 }
            .prefix(1)
            .sink { _ in seen = coordinator.isRehearsal }

        await coordinator.start(rehearsal: true)
        sink.cancel()

        #expect(seen == true)
    }

    @Test("a rehearsal restores the previous transcript on stop")
    func transcriptRestored() async {
        let mocks = RehearsalCoordinatorMocks()
        let coordinator = makeRehearsalCoordinator(mocks)
        _ = coordinator.appendTranscript(.outgoing, "first")
        _ = coordinator.appendTranscript(.outgoing, "second")
        let original = coordinator.transcript

        await coordinator.start(rehearsal: true)
        #expect(coordinator.transcript.isEmpty)
        _ = coordinator.appendTranscript(.outgoing, "rehearsal entry")

        await coordinator.stop()

        #expect(coordinator.transcript == original)
        #expect(!coordinator.isRehearsal)
    }

    @Test("pipeline errors during a rehearsal go to lastRehearsalError, then clear on stop")
    func errorsGoToRehearsal() async {
        let mocks = RehearsalCoordinatorMocks()
        let coordinator = makeRehearsalCoordinator(mocks)
        await coordinator.start(rehearsal: true)

        coordinator.errorAlert = AlertItem(title: "t", message: "m", action: nil)

        #expect(coordinator.lastRehearsalError?.message == "m")

        await coordinator.stop()

        #expect(coordinator.errorAlert == nil)
        #expect(!coordinator.isRehearsal)
    }

    @Test("missing translation packs end the rehearsal with lastRehearsalError")
    func packsMissingEndsRehearsal() async {
        let mocks = RehearsalCoordinatorMocks()
        let coordinator = makeRehearsalCoordinator(mocks, isTranslationPairInstalled: { _, _ in false })

        await coordinator.start(rehearsal: true)

        #expect(!coordinator.isRehearsal)
        #expect(coordinator.lastRehearsalError != nil)
        #expect(coordinator.errorAlert == nil)
    }

    @Test("a normal start clears the transcript and never sets isRehearsal")
    func normalStartUnaffected() async {
        let mocks = RehearsalCoordinatorMocks()
        let coordinator = makeRehearsalCoordinator(mocks)
        _ = coordinator.appendTranscript(.outgoing, "previous")
        #expect(!coordinator.transcript.isEmpty)

        await coordinator.start()

        #expect(!coordinator.isRehearsal)
        #expect(coordinator.transcript.isEmpty)
    }
}
