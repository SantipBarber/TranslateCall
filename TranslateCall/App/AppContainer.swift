import Combine
import Foundation

/// Owns and wires the full M4 object graph.
///
/// Dependency order:
/// 1. `LanguagePairManager` (no deps)
/// 2. `AudioManager` (no deps)
/// 3. `TranslationBridgeModel` × 2 (outgoing + incoming, no deps)
/// 4. `AppleTranslationService` × 2 (depend on bridge models)
/// 5. `AudioCoordinator` (depends on audio manager + translation services + language pair manager)
/// 6. `AudioViewModel` (depends on coordinator + audio manager + language pair manager)
@MainActor
final class AppContainer: ObservableObject {
    let outgoingBridgeModel: TranslationBridgeModel
    let incomingBridgeModel: TranslationBridgeModel
    let audioCoordinator: AudioCoordinator
    let audioViewModel: AudioViewModel
    let languagePairManager: LanguagePairManager

    init() {
        let lpm = LanguagePairManager()
        let audioManager = AudioManager()
        let outBridge = TranslationBridgeModel()
        let inBridge = TranslationBridgeModel()
        let outTranslation = AppleTranslationService(model: outBridge)
        let inTranslation = AppleTranslationService(model: inBridge)

        let coordinator = AudioCoordinator(
            audioCapture: audioManager,
            systemCapture: SystemAudioCaptureService(),
            outgoingVADFactory: { EnergyVADService() },
            incomingVADFactory: { EnergyVADService() },
            outgoingSTTFactory: { AppleSpeechService(locale: $0) },
            incomingSTTFactory: { AppleSpeechService(locale: $0) },
            outgoingTranslationService: outTranslation,
            incomingTranslationService: inTranslation,
            outgoingTTSFactory: { try AVSpeechService(outputDeviceID: $0) },
            incomingTTSFactory: { _ in try AVSpeechService(outputDeviceID: nil) },
            languagePairManager: lpm
        )

        outgoingBridgeModel = outBridge
        incomingBridgeModel = inBridge
        languagePairManager = lpm
        audioCoordinator = coordinator
        audioViewModel = AudioViewModel(
            coordinator: coordinator,
            audioManager: audioManager,
            languagePairManager: lpm
        )
    }
}
