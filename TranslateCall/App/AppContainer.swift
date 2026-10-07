import Combine
import Foundation

/// Owns and wires the full M8 object graph.
///
/// Dependency order:
/// 1. `LanguagePairManager` (no deps)
/// 2. `AudioManager` (no deps)
/// 3. `SetupManager` (no deps)
/// 4. `TranslationBridgeModel` × 2 (outgoing + incoming, no deps), hosted off-screen by `TranslationHostWindow`
/// 5. `TranslationEngineSelector` (depends on bridge models)
/// 6. `AudioCoordinator` (depends on audio manager + translation services + language pair manager)
/// 7. `AudioViewModel` (depends on coordinator + audio manager + language pair manager + setup manager)
@MainActor
final class AppContainer: ObservableObject {
    let outgoingBridgeModel: TranslationBridgeModel
    let incomingBridgeModel: TranslationBridgeModel
    /// Keeps both bridges running with the main window closed (F8.5.4 REQ-TR-30/31).
    let translationHost: TranslationHostWindow
    let translationSelector: TranslationEngineSelector
    let audioCoordinator: AudioCoordinator
    let audioViewModel: AudioViewModel
    let languagePairManager: LanguagePairManager
    let setupManager: SetupManager
    let voiceProfileManager: VoiceProfileManager
    let conversationSettings: ConversationSettings
    let vadProvider: VADProvider

    /// True inside the unit/integration test host: no model is warmed there (models stay out of unit tests).
    nonisolated static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        let lpm = LanguagePairManager()
        let audioManager = AudioManager()
        let setup = SetupManager()
        let outBridge = TranslationBridgeModel()
        let inBridge = TranslationBridgeModel()
        translationHost = TranslationHostWindow(outgoing: outBridge, incoming: inBridge)
        let translationSel = TranslationEngineSelector(outgoingBridge: outBridge, incomingBridge: inBridge)
        let selector = STTEngineSelector()
        let ttsSelector = TTSEngineSelector()
        let settings = ConversationSettings()
        let vads = VADProvider()
        if !Self.isTestHost { vads.preload() }
        let coordinator = AudioCoordinator(
            audioCapture: audioManager,
            systemCapture: SystemAudioCaptureService(),
            // Read at each session start: "Pause to translate" applies to the next session (REQ-V-05).
            outgoingVADFactory: { await vads.makeVAD(config: settings.vadConfiguration) },
            incomingVADFactory: { await vads.makeVAD(config: settings.vadConfiguration) },
            outgoingSTTFactory: { selector.makeOutgoingService(for: $0) },
            incomingSTTFactory: { selector.makeIncomingService(for: $0) },
            outgoingTranslationService: translationSel.makeOutgoingService(),
            incomingTranslationService: translationSel.makeIncomingService(),
            outgoingTTSFactory: { [ttsSelector] in try ttsSelector.makeOutgoingService(for: $0, deviceID: $1) },
            incomingTTSFactory: { [ttsSelector] in try ttsSelector.makeIncomingService(for: $0, deviceID: $1) },
            languagePairManager: lpm
        )

        let voiceProfiles = VoiceProfileManager(
            store: VoiceProfileStore(),
            recorder: VoiceProfileRecorder(),
            isSessionActive: { audioManager.isCapturing }
        )
        outgoingBridgeModel = outBridge
        incomingBridgeModel = inBridge
        translationSelector = translationSel
        languagePairManager = lpm
        setupManager = setup
        voiceProfileManager = voiceProfiles
        conversationSettings = settings
        vadProvider = vads
        audioCoordinator = coordinator
        audioViewModel = AudioViewModel(
            coordinator: coordinator,
            audioManager: audioManager,
            languagePairManager: lpm,
            setupManager: setup,
            engineSelector: selector,
            ttsEngineSelector: ttsSelector,
            voiceProfileManager: voiceProfiles,
            conversationSettings: settings,
            vadProvider: vads
        )
    }
}
