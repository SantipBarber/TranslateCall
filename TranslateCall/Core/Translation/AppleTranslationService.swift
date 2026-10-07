import Foundation
@preconcurrency import Translation

/// `TranslationService` over Apple's Translation framework. Requests go through this direction's
/// `TranslationBridgeModel`, which owns the session, the queue, the timeout and the retry (F8.5.4).
/// The model is held strongly: `AppContainer` owns both for the app's lifetime (REQ-TR-22, REQ-TR-60).
final class AppleTranslationService: TranslationService {
    let model: TranslationBridgeModel

    init(model: TranslationBridgeModel) {
        self.model = model
    }

    var engineName: String { "Apple Translation" }

    func translate(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        try await model.translate(text, from: source, to: target)
    }

    func warmUp(from source: Locale.Language, to target: Locale.Language) async {
        model.warmUp(from: source, to: target)
    }

    /// Whether the pair's models are downloaded (F8.5.4 REQ-TR-06). The call-time bridges live in a hidden
    /// window and cannot show the download sheet, so `AudioCoordinator.start` requires `.installed`.
    static func isInstalled(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        await LanguageAvailability().status(from: source, to: target) == .installed
    }
}
