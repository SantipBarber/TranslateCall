import Foundation

// MARK: - EdgeTTSConsentManager

/// Manages one-time user consent for Edge TTS (cloud-based synthesis).
/// Edge TTS sends text to Microsoft servers — user must explicitly opt in.
enum EdgeTTSConsentManager {
    nonisolated private static let consentKey = "tlk.edgeTTS.consentGiven"

    static var consentGiven: Bool {
        UserDefaults.standard.bool(forKey: consentKey)
    }

    nonisolated static func grantConsent(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: consentKey)
    }

    nonisolated static func revokeConsent(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: consentKey)
    }
}
