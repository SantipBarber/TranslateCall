import Foundation

extension AudioViewModel {
    /// No system voice for the target locale, the cloud allowed and no Edge consent yet: a start must
    /// first show the consent dialog, so it needs the main window (REQ-UI-36, REQ-ST-32).
    var needsEdgeConsentBeforeStart: Bool {
        let targetLocale = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
        return ttsEngineSelector.needsEdgeConsent(for: targetLocale)
    }
}
