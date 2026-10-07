import Foundation
import Testing
@testable import TranslateCall

/// Records the pack checks `start` makes and answers them from `installed` (REQ-TR-06).
@MainActor
private final class PackChecks {
    var installed: (Locale.Language, Locale.Language) -> Bool = { _, _ in true }
    private(set) var asked: [(source: Locale.Language, target: Locale.Language)] = []

    func check(_ source: Locale.Language, _ target: Locale.Language) -> Bool {
        asked.append((source, target))
        return installed(source, target)
    }
}

@MainActor
private func makeCoordinator(
    _ mocks: CoordinatorMocks,
    packs: PackChecks = PackChecks(),
    packCheck: (@MainActor (Locale.Language, Locale.Language) async -> Bool)? = nil
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
        noticeClock: TestClock(),
        isTranslationPairInstalled: { await (packCheck?($0, $1) ?? packs.check($0, $1)) }
    )
}

private func transcript(_ text: String) -> TranscriptionResult {
    TranscriptionResult(text: text, confidence: 1, locale: Locale(identifier: "es-ES"), capturedAt: .now, audioDuration: 1)
}

@Suite("AudioCoordinator translation (F8.5.4)", .serialized) @MainActor
struct AudioCoordinatorTranslationTests {

    @Test("start warms up both directions with their own pair (REQ-TR-05)")
    func startWarmsUpBothDirections() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()

        // The mocks' LanguagePairManager has an empty loader, so its pair is fixed: source -> target outgoing.
        let pair = (source: mocks.languagePairManager.sourceLanguage, target: mocks.languagePairManager.targetLanguage)
        let outgoing = mocks.mockOutgoingTranslation.warmUpCalls
        let incoming = mocks.mockIncomingTranslation.warmUpCalls
        #expect(outgoing.count == 1 && incoming.count == 1)
        #expect(outgoing.first?.source == pair.source && outgoing.first?.target == pair.target)
        #expect(incoming.first?.source == pair.target && incoming.first?.target == pair.source)
        #expect(outgoing.first?.source == incoming.first?.target)
        #expect(outgoing.first?.target == incoming.first?.source)
        #expect(outgoing.first?.source != outgoing.first?.target)
        await coordinator.stop()
    }

    @Test("Start checks both directions' packs before anything else (REQ-TR-06)")
    func startChecksBothDirections() async {
        let mocks = CoordinatorMocks()
        let packs = PackChecks()
        let coordinator = makeCoordinator(mocks, packs: packs)
        await coordinator.start()

        #expect(packs.asked.count == 2)
        #expect(packs.asked.first?.source == packs.asked.last?.target)
        #expect(packs.asked.first?.target == packs.asked.last?.source)
        #expect(coordinator.isOutgoingActive)
        await coordinator.stop()
    }

    @Test("a pair that is not downloaded blocks Start with the download alert (REQ-TR-06)")
    func missingPackBlocksStart() async {
        let mocks = CoordinatorMocks()
        let packs = PackChecks()
        packs.installed = { _, _ in false }
        let coordinator = makeCoordinator(mocks, packs: packs)
        await coordinator.start()

        #expect(coordinator.errorAlert?.title == "Languages Not Downloaded")
        #expect(!coordinator.isOutgoingActive)
        #expect(!coordinator.isStarting)
        #expect(!mocks.mockAudioCapture.startCaptureCalled)
        #expect(mocks.mockOutgoingTranslation.warmUpCalls.isEmpty)
        #expect(mocks.mockIncomingTranslation.warmUpCalls.isEmpty)
    }

    @Test("a Stop during the pack check supersedes Start: no alert, no capture, no warm-up")
    func stopDuringPackCheckShowsNoAlert() async {
        let mocks = CoordinatorMocks()
        var release: CheckedContinuation<Bool, Never>?
        var entered = false
        let coordinator = makeCoordinator(mocks, packCheck: { _, _ in
            await withCheckedContinuation { continuation in
                release = continuation
                entered = true
            }
        })
        let starting = Task { await coordinator.start() }
        #expect(await waitUntil { entered })

        await coordinator.stop()
        release?.resume(returning: false)   // the check answers "not installed" after the Stop
        await starting.value

        #expect(coordinator.errorAlert == nil)
        #expect(!coordinator.isOutgoingActive)
        #expect(!mocks.mockAudioCapture.startCaptureCalled)
        #expect(mocks.mockOutgoingTranslation.warmUpCalls.isEmpty)
        #expect(mocks.mockIncomingTranslation.warmUpCalls.isEmpty)
    }

    @Test("one missing direction is enough to block Start (REQ-TR-06)")
    func missingReverseDirectionBlocksStart() async {
        let mocks = CoordinatorMocks()
        let packs = PackChecks()
        var first = true
        packs.installed = { _, _ in
            defer { first = false }
            return first   // outgoing installed, incoming not
        }
        let coordinator = makeCoordinator(mocks, packs: packs)
        await coordinator.start()

        #expect(packs.asked.count == 2)
        #expect(coordinator.errorAlert?.title == "Languages Not Downloaded")
        #expect(!coordinator.isOutgoingActive)
        #expect(!mocks.mockAudioCapture.startCaptureCalled)
    }

    @Test("a sentence that cannot be translated is skipped with a notice, no alert; the next one is spoken (REQ-TR-20)")
    func outgoingFailureIsANotice() async {
        let mocks = CoordinatorMocks()
        mocks.mockOutgoingTranslation.errors = [TranslationError.timedOut]
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()

        await mocks.mockOutgoingSTT.injectTranscription(transcript("uno"))
        #expect(await waitUntil { coordinator.ttsNotice == "Couldn't translate your sentence — skipped" })
        await mocks.mockOutgoingSTT.injectTranscription(transcript("dos"))
        #expect(await waitUntil { await mocks.mockOutgoingTTS.speakCalls.count == 1 })
        #expect(await mocks.mockOutgoingTTS.speakCalls.first?.text == "TRANSLATED: dos")
        #expect(coordinator.errorAlert == nil)
        await coordinator.stop()
    }

    @Test("an incoming failure names the other side (REQ-TR-20)")
    func incomingFailureIsANotice() async {
        let mocks = CoordinatorMocks()
        mocks.mockIncomingTranslation.errors = [TranslationError.sessionError(CancellationError())]
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { coordinator.isIncomingActive })

        await mocks.mockIncomingSTT.injectTranscription(transcript("hello"))
        #expect(await waitUntil { coordinator.ttsNotice == "Couldn't translate their sentence — skipped" })
        #expect(coordinator.errorAlert == nil)
        await coordinator.stop()
    }

    @Test("a configuration error alerts once per session; the next session starts clean (REQ-TR-21)")
    func configurationErrorAlertsOncePerSession() async {
        let mocks = CoordinatorMocks()
        let unsupported = TranslationError.unsupportedPair(Locale.Language(identifier: "es"),
                                                           Locale.Language(identifier: "tlh"))
        mocks.mockOutgoingTranslation.shouldThrow = unsupported
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()

        await mocks.mockOutgoingSTT.injectTranscription(transcript("uno"))
        #expect(await waitUntil { coordinator.errorAlert?.title == "Language Pair Unsupported" })
        coordinator.errorAlert = nil
        await mocks.mockOutgoingSTT.injectTranscription(transcript("dos"))
        #expect(await waitUntil { mocks.mockOutgoingTranslation.translateCallCount == 2 })
        #expect(coordinator.errorAlert == nil)
        #expect(coordinator.ttsNotice == nil)

        await coordinator.stop()
        await coordinator.start()   // the mock STT stream ended with the first session: check the reset directly
        #expect(coordinator.alertedTranslationErrors.isEmpty)
        await coordinator.stop()
    }

    @Test("a cancelled translation (session stopping) is silent")
    func cancellationIsSilent() async {
        let mocks = CoordinatorMocks()
        mocks.mockOutgoingTranslation.errors = [CancellationError()]
        let coordinator = makeCoordinator(mocks)
        await coordinator.start()

        await mocks.mockOutgoingSTT.injectTranscription(transcript("uno"))
        #expect(await waitUntil { mocks.mockOutgoingTranslation.translateCallCount == 1 })
        await mocks.mockOutgoingSTT.injectTranscription(transcript("dos"))
        #expect(await waitUntil { await mocks.mockOutgoingTTS.speakCalls.count == 1 })
        #expect(coordinator.errorAlert == nil)
        #expect(coordinator.ttsNotice == nil)
        await coordinator.stop()
    }
}
