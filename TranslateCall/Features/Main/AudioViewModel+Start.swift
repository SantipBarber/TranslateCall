import AVFoundation
import Foundation

extension AudioViewModel {
    /// No system voice for the target locale and no Edge TTS consent given: a start must first show
    /// the consent dialog, so it needs the main window (REQ-UI-36).
    var needsEdgeConsentBeforeStart: Bool {
        let targetLocale = Locale(identifier: languagePairManager.targetLanguage.minimalIdentifier)
        return !AVSpeechUtteranceSynthesizer.hasVoice(for: targetLocale) && !EdgeTTSConsentManager.consentGiven
    }
}
