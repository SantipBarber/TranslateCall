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
}
