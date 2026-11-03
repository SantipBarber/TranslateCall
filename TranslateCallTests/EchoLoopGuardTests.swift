import CoreAudio
import Foundation
import Testing
@testable import TranslateCall

/// The Task 18 Q6 loop: speakers detected on the output, and the mic's echo of their translation.
@Suite("Echo loop guards")
struct EchoLoopGuardTests {
    // MARK: Output route

    @Test func builtInSpeakersAreSpeakers() {
        #expect(OutputRoute.classify(transport: kAudioDeviceTransportTypeBuiltIn,
                                     dataSource: OutputRoute.internalSpeakers) == .speakers)
        #expect(OutputRoute.classify(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: nil) == .speakers)
        #expect(OutputRoute.classify(transport: kAudioDeviceTransportTypeBuiltIn,
                                     dataSource: OutputRoute.headphonesJack) == .headphones)
    }

    @Test func otherTransports() {
        #expect(OutputRoute.classify(transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil) == .headphones)
        #expect(OutputRoute.classify(transport: kAudioDeviceTransportTypeHDMI, dataSource: nil) == .speakers)
        #expect(OutputRoute.classify(transport: kAudioDeviceTransportTypeAirPlay, dataSource: nil) == .speakers)
        #expect(OutputRoute.classify(transport: kAudioDeviceTransportTypeUSB, dataSource: nil) == .unknown)
        #expect(OutputRoute.classify(transport: kAudioDeviceTransportTypeVirtual, dataSource: nil) == .unknown)
    }

    @Test func detectionOnlyRaisesTheMode() {
        #expect(ListeningMode.effective(chosen: .headphones, route: .speakers) == .speakers)
        #expect(ListeningMode.effective(chosen: .headphones, route: .unknown) == .headphones)
        #expect(ListeningMode.effective(chosen: .speakers, route: .headphones) == .speakers)
    }

    // MARK: Self-echo guard (sentences from the echo-headphones-both scenario, 2026-11-03)

    private let played = "El zumo de col cambia de color dependiendo de lo estético y alcalino básico que sea el químico."

    @Test func recognizedEchoIsDropped() {
        var guardian = SelfEchoGuard()
        let now = ContinuousClock.now
        guardian.played(played, at: now)
        let echo = "El zumo de contendía de color dependiendo de lo estético y alcalino básico que sea el químico"
        #expect(guardian.isEcho(echo, at: now + .seconds(8)))
        #expect(!guardian.isEcho(echo, at: now + .seconds(21)), "outside the window")
    }

    @Test func theUsersOwnSentencesGetThrough() {
        var guardian = SelfEchoGuard()
        let now = ContinuousClock.now
        guardian.played(played, at: now)
        #expect(!guardian.isEcho("Sí, el químico", at: now), "short replies are never echoes")
        #expect(!guardian.isEcho("¿Has dicho que el zumo de col cambia de color?", at: now), "quoting them back")
        #expect(!guardian.isEcho("Mañana te mando el informe con los resultados", at: now))
    }

    @Test func aGarbledEchoIsCaughtByItsTiming() {
        var guardian = SelfEchoGuard()
        let now = ContinuousClock.now
        guardian.played("Es la cena debajo de la zona y más gruesa debajo de las Highlands.", at: now)
        guardian.playing(true, at: now)
        let garbled = "Es la cena de vasco de la zona hay más gruesa debajo de las galanes"   // 0.75
        #expect(guardian.isEcho(garbled, at: now + .seconds(3)), "while it plays")
        guardian.playing(false, at: now + .seconds(4))
        #expect(guardian.isEcho(garbled, at: now + .seconds(5.5)), "just after")
        #expect(!guardian.isEcho(garbled, at: now + .seconds(7)), "later, only a close match counts")
    }

    @Test func quotingThemBackWhileTheyPlayIsStillAllowedBelowTheBar() {
        var guardian = SelfEchoGuard()
        let now = ContinuousClock.now
        guardian.played(played, at: now)
        guardian.playing(true, at: now)
        #expect(!guardian.isEcho("Mañana te mando el informe con los resultados del químico", at: now))
    }

    @Test func resetForgets() {
        var guardian = SelfEchoGuard()
        let now = ContinuousClock.now
        guardian.played(played, at: now)
        guardian.reset()
        #expect(!guardian.isEcho(played, at: now))
    }
}

@Suite("Echo loop guards — wiring", .serialized) @MainActor
struct EchoLoopWiringTests {
    private func makeCoordinator(_ mocks: CoordinatorMocks,
                                 incomingDevice: @escaping (AudioDeviceID?) -> Void = { _ in }) -> AudioCoordinator {
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
            incomingTTSFactory: { _, device in incomingDevice(device); return mocks.mockIncomingTTS },
            languagePairManager: mocks.languagePairManager,
            noticeClock: TestClock(),
            isTranslationPairInstalled: { _, _ in true }
        )
    }

    private func transcript(_ text: String) -> TranscriptionResult {
        TranscriptionResult(text: text, confidence: 1, locale: Locale(identifier: "es-ES"), capturedAt: .now,
                            audioDuration: 1)
    }

    @Test("the mic's echo of their translation is not spoken into the call; the user's next sentence is")
    func echoIsNotSpokenBack() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        await coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { coordinator.isIncomingActive })

        // The mock translator answers "TRANSLATED: <text>".
        await mocks.mockIncomingSTT.injectTranscription(transcript("el zumo de col cambia de color con el pH"))
        #expect(await waitUntil { await mocks.mockIncomingTTS.speakCalls.count == 1 })
        await mocks.mockOutgoingSTT.injectTranscription(transcript("el zumo de col cambia de color con el ph"))
        #expect(await waitUntil { coordinator.ttsNotice?.hasPrefix("Ignored an echo") == true })
        await mocks.mockOutgoingSTT.injectTranscription(transcript("mañana te mando el informe completo"))
        #expect(await waitUntil { await mocks.mockOutgoingTTS.speakCalls.count == 1 })
        #expect(await mocks.mockOutgoingTTS.speakCalls.first?.text == "TRANSLATED: mañana te mando el informe completo")
        await coordinator.stop()
    }

    @Test("their translation plays on the output chosen in Settings")
    func incomingPlaysOnTheChosenOutput() async {
        let mocks = CoordinatorMocks()
        var asked: [AudioDeviceID?] = []
        let coordinator = makeCoordinator(mocks) { asked.append($0) }
        coordinator.incomingOutputDeviceID = 77
        await coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { coordinator.isIncomingActive })
        #expect(asked == [77])
        await coordinator.stop()
    }

    @Test("speakers detected on the output put the gate in speakers mode; the chosen output is watched")
    func detectedSpeakersRaiseTheMode() async {
        let mocks = CoordinatorMocks()
        let coordinator = makeCoordinator(mocks)
        var watched: [AudioDeviceID?] = []
        let monitor = OutputRouteMonitor(resolve: { id in watched.append(id); return id == 5 ? .speakers : .unknown })
        let viewModel = AudioViewModel(
            coordinator: coordinator,
            audioManager: AudioManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                                       configure: { _, _ in }),
            languagePairManager: mocks.languagePairManager,
            setupManager: SetupManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!),
            conversationSettings: ConversationSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!),
            outputRoute: monitor
        )
        #expect(viewModel.effectiveListeningMode == .headphones)
        viewModel.selectedOutput = AudioDevice(id: 5, name: "Mac mini Speakers", uid: "spk", hasInput: false,
                                               hasOutput: true)
        #expect(await waitUntil { coordinator.listeningMode == .speakers })
        #expect(viewModel.effectiveListeningMode == .speakers)
        #expect(viewModel.conversationSettings.listeningMode == .headphones, "the user's choice is kept")
        #expect(coordinator.incomingOutputDeviceID == 5)
        #expect(watched.last == 5)
    }
}
