import Combine
import Foundation

/// Owns and wires the full M3 object graph.
/// `TranslationBridgeModel` must be created before `AppleTranslationService`,
/// which in turn must be created before `AudioViewModel` — a dependency chain
/// that cannot be expressed with independent `@StateObject` declarations.
@MainActor
final class AppContainer: ObservableObject {
    let translationBridgeModel: TranslationBridgeModel
    let audioViewModel: AudioViewModel

    init() {
        let bridge = TranslationBridgeModel()
        let lpm = LanguagePairManager()
        let translationService = AppleTranslationService(model: bridge)
        translationBridgeModel = bridge
        audioViewModel = AudioViewModel(translationService: translationService, languagePairManager: lpm)
    }
}
