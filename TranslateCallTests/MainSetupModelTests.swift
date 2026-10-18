import Combine
import Foundation
import Testing
@testable import TranslateCall

/// A MainSetupModel over Zoom (installed, not running), with fakes for packs and permissions.
@MainActor
private struct SetupHarness {
    let workspace = FakeWorkspace()
    let monitor: CallAppMonitor
    let setupManager: SetupManager
    let languages: LanguagePairManager
    let tts = TTSEngineSelector(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
    let models: ModelServices
    let model: MainSetupModel

    init(installed: @escaping (Locale.Language, Locale.Language) async -> Bool = { _, _ in true },
         permissions: @escaping () -> PermissionState = { .allGranted }) {
        workspace.installed = ["us.zoom.xos": "zoom.us"]
        monitor = CallAppMonitor(workspace: workspace)
        setupManager = SetupManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defaults.set("de", forKey: "tlk.source.language")
        defaults.set("en", forKey: "tlk.target.language")
        languages = LanguagePairManager(defaults: defaults, languageLoader: { [] })
        let mocks = CoordinatorMocks()
        let coordinator = AudioCoordinator(
            audioCapture: mocks.mockAudioCapture, systemCapture: mocks.mockSystemCapture,
            outgoingVADFactory: { mocks.mockVADFactory }, incomingVADFactory: { mocks.mockIncomingVAD },
            outgoingSTTFactory: { _ in mocks.mockOutgoingSTT }, incomingSTTFactory: { _ in mocks.mockIncomingSTT },
            outgoingTranslationService: mocks.mockOutgoingTranslation,
            incomingTranslationService: mocks.mockIncomingTranslation,
            outgoingTTSFactory: { _, _ in mocks.mockOutgoingTTS }, incomingTTSFactory: { _, _ in mocks.mockIncomingTTS },
            languagePairManager: mocks.languagePairManager,
            echoGateClock: TestClock(), noticeClock: TestClock(),
            isTranslationPairInstalled: { _, _ in true }
        )
        let viewModel = AudioViewModel(
            coordinator: coordinator,
            audioManager: AudioManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                                       configure: { _, _ in }),
            languagePairManager: mocks.languagePairManager, setupManager: setupManager,
            conversationSettings: ConversationSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        )
        let session = CallSessionModel(coordinator: coordinator, viewModel: viewModel)
        tts.cacheProbe = .none
        tts.edgeConsentGiven = { true }
        tts.catalog = ModelCatalog(version: 2, stt: [:], ttsOutgoing: [:], ttsIncoming: [:])   // Edge available
        let modelDefaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        models = ModelServices(choices: PairModelChoices(defaults: modelDefaults),
                               cloud: CloudPolicy(defaults: modelDefaults, edgeConsentGiven: { true },
                                                  grantEdgeConsent: {}),
                               downloads: ModelDownloads(probe: .none, managers: DownloadManagers(
                                   download: { _ in }, cancel: { _ in })),
                               stt: STTEngineSelector(), tts: tts, languagePairManager: languages)
        models.cloud.allowed = false
        model = MainSetupModel(monitor: monitor, setupManager: setupManager, languagePairManager: languages,
                               session: session, models: models, tts: tts,
                               isInstalled: installed, permissions: permissions)
    }

    var zoom: CallAppRow { monitor.rows.first { $0.bundleID == "us.zoom.xos" }! }
}

@Suite("MainSetupModel (M9 UI core)") @MainActor
struct MainSetupModelTests {

    @Test("select writes through to the setup manager")
    func selectWritesThroughToSetupManager() {
        let harness = SetupHarness()
        harness.model.select(harness.zoom)
        #expect(harness.setupManager.selectedCaptureBundleID == "us.zoom.xos")
        #expect(harness.model.selectedRow?.title == "Zoom")
    }

    @Test("None clears the capture target")
    func selectOtherNoneClearsTarget() {
        let harness = SetupHarness()
        harness.model.select(harness.zoom)
        harness.model.selectOther(bundleID: nil)
        #expect(harness.setupManager.captureTarget == nil)
        #expect(harness.model.selectedRow == nil)
    }

    @Test("the pair is checked per direction")
    func pairCheckedPerDirection() async {
        let source = Locale.Language(identifier: "de")
        let harness = SetupHarness(installed: { from, _ in from == source })
        await harness.model.refresh()
        let name = harness.languages.displayName(for: harness.languages.sourceLanguage)
        #expect(harness.model.pair == .missing(language: name))
        #expect(harness.model.readiness.primary == .download(name))
    }

    @Test("Other app adds its row and selects it without a relaunch")
    func selectOtherAddsRow() {
        let harness = SetupHarness()
        harness.workspace.installed["com.example.Call"] = "Example Call"
        harness.model.selectOther(bundleID: "com.example.Call")
        #expect(harness.monitor.rows.last?.title == "Example Call")
        #expect(harness.model.selectedRow?.bundleID == "com.example.Call")
    }

    @Test("a call app that is not running makes the primary Open and start")
    func openAppAndStartWhenNotRunning() async {
        let harness = SetupHarness()
        harness.model.select(harness.zoom)
        await harness.model.refresh()
        #expect(harness.model.readiness.primary == .openAppAndStart("Zoom"))
    }

    @Test("a denied microphone blocks Start")
    func deniedMicBlocksStart() async {
        let harness = SetupHarness(permissions: { PermissionState(microphone: .denied, screenRecording: .granted) })
        await harness.model.refresh()
        #expect(harness.model.readiness.cards.first == .microphoneOff)
        #expect(!harness.model.readiness.primaryEnabled)
    }

    @Test("a session change that changes nothing here publishes nothing; the pair the views read is published")
    func publishesOnlyChanges() async {
        let harness = SetupHarness()
        await mainQueueHop()
        let changes = CallCounter()
        let subscription = harness.model.objectWillChange.sink { changes.increment() }
        harness.model.session.objectWillChange.send()
        await mainQueueHop()
        #expect(changes.value == 0)

        await harness.languages.setTargetLanguage(Locale.Language(identifier: "es"))
        #expect(await waitUntil { harness.model.targetLanguage == Locale.Language(identifier: "es") })
        #expect(changes.value > 0)
        subscription.cancel()
    }

    @Test("the models line: Recommended; Custom with a pair choice; · Cloud when Edge will speak (REQ-ST-05, 40)")
    func modelsLabel() async {
        let harness = SetupHarness()
        #expect(harness.model.modelsLabel == "Models: Recommended")
        harness.models.choices.set(PairModelChoice(stt: .appleSpeech), for: PairKey("en", "de"))
        #expect(await waitUntil { harness.model.modelsLabel == "Models: Custom" })
        harness.tts.hasSystemVoice = { _ in false }
        harness.models.cloud.allowed = true
        #expect(await waitUntil { harness.model.modelsLabel == "Models: Custom · Cloud" })
        #expect(ModelsLabel.text(hasChoice: false, usesCloud: true) == "Models: Recommended · Cloud")
    }

    @Test("a session tick does not recompute the models line (no disk or voice probes mid-call)")
    func sessionTickSkipsModelsLabel() async {
        let harness = SetupHarness()
        await mainQueueHop()
        let probes = CallCounter()
        harness.tts.hasSystemVoice = { _ in probes.increment(); return true }
        harness.model.session.objectWillChange.send()
        await mainQueueHop()
        #expect(probes.value == 0)
        harness.models.cloud.allowed = true
        #expect(await waitUntil { probes.value > 0 }, "its own inputs still recompute it")
    }
}
