import Combine
import Foundation

// MARK: - TranslationEngineSelector

/// Routes translation requests to the appropriate backend.
/// M8: only Apple Translation. Future milestones add Opus-MT, LibreTranslate, etc.
@MainActor
final class TranslationEngineSelector: ObservableObject {
    @Published private(set) var preferredEngine: TranslationEngine

    private let defaults: UserDefaults
    private let outgoingBridge: TranslationBridgeModel
    private let incomingBridge: TranslationBridgeModel
    private static let defaultsKey = "tlk.translation.engine"

    init(
        outgoingBridge: TranslationBridgeModel,
        incomingBridge: TranslationBridgeModel,
        defaults: UserDefaults = .standard
    ) {
        self.outgoingBridge = outgoingBridge
        self.incomingBridge = incomingBridge
        self.defaults = defaults
        self.preferredEngine = defaults.string(forKey: Self.defaultsKey)
            .flatMap { TranslationEngine(rawValue: $0) } ?? .appleTranslation
    }

    // MARK: - Service Factories

    func makeOutgoingService() -> any TranslationService {
        switch preferredEngine {
        case .appleTranslation:
            return AppleTranslationService(model: outgoingBridge)
        }
    }

    func makeIncomingService() -> any TranslationService {
        switch preferredEngine {
        case .appleTranslation:
            return AppleTranslationService(model: incomingBridge)
        }
    }

    // MARK: - Language Pair Support

    func supports(
        source: Locale.Language,
        target: Locale.Language
    ) async -> Bool {
        await makeOutgoingService().supports(source: source, target: target)   // one source of truth (REQ-TR-51)
    }

    // MARK: - Engine Selection

    func setPreferredEngine(_ engine: TranslationEngine) {
        preferredEngine = engine
        defaults.set(engine.rawValue, forKey: Self.defaultsKey)
    }
}
