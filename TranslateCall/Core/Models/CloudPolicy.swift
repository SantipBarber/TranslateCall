import Combine
import Foundation

// MARK: - CloudSnapshot

/// What the cloud rules allow right now, as a value for the pure resolution (M9 UI settings REQ-ST-02, 32).
nonisolated struct CloudSnapshot: Equatable, Sendable {
    /// "Allow cloud models" (Settings › Advanced).
    var allowed = false
    /// Cloud engines the user consented to.
    var consented: Set<TTSEngine> = []
    /// Cloud engines the catalog marks unavailable (S-3).
    var unavailable: Set<TTSEngine> = []

    /// A cloud engine may run: allowed, consented and not marked unavailable (NFR-ST-02).
    func permits(_ engine: TTSEngine) -> Bool {
        allowed && consented.contains(engine) && !unavailable.contains(engine)
    }
}

// MARK: - CloudPolicy

/// "Allow cloud models" and per-engine consent (REQ-ST-15, 32). Edge TTS is the only cloud engine;
/// its consent stays in `EdgeTTSConsentManager` (machine-wide), injected so tests never touch it.
@MainActor
final class CloudPolicy: ObservableObject {
    static let allowedKey = "tlk.cloud.allowed"

    @Published var allowed: Bool {
        didSet { defaults.set(allowed, forKey: Self.allowedKey) }
    }

    private let defaults: UserDefaults
    private let edgeConsentGiven: () -> Bool
    private let grantEdgeConsent: () -> Void

    /// The first read defaults to the existing Edge consent, then is stored (REQ-ST-32).
    init(defaults: UserDefaults = .standard,
         edgeConsentGiven: @escaping () -> Bool = { EdgeTTSConsentManager.consentGiven },
         grantEdgeConsent: @escaping () -> Void = { EdgeTTSConsentManager.grantConsent() }) {
        self.defaults = defaults
        self.edgeConsentGiven = edgeConsentGiven
        self.grantEdgeConsent = grantEdgeConsent
        let stored = defaults.object(forKey: Self.allowedKey) as? Bool
        allowed = stored ?? edgeConsentGiven()
        if stored == nil { defaults.set(allowed, forKey: Self.allowedKey) }
    }

    func hasConsent(_ engine: TTSEngine) -> Bool {
        engine == .edgeTTS && edgeConsentGiven()
    }

    func grantConsent(_ engine: TTSEngine) {
        guard engine == .edgeTTS else { return }
        objectWillChange.send()
        grantEdgeConsent()
    }
}
