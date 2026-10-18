import Foundation

// MARK: - ModelServices

/// The per-pair model choices and the cloud policy, wired into both selectors (M9 UI settings P1, P20).
/// Lives in `UIServices`; Task 6 adds the downloads.
@MainActor
struct ModelServices {
    let choices: PairModelChoices
    let cloud: CloudPolicy

    /// Production: the stores in `UserDefaults.standard` and the machine-wide Edge consent.
    /// `isSessionActive` is for the downloads, which must not start during a call (S-7).
    init(stt: STTEngineSelector, tts: TTSEngineSelector, languagePairManager: LanguagePairManager,
         isSessionActive _: @escaping () -> Bool) {
        self.init(choices: PairModelChoices(), cloud: CloudPolicy(), stt: stt, tts: tts,
                  languagePairManager: languagePairManager)
    }

    /// Injected (tests): wires `pairChoice` of both selectors to the current pair, and `cloudAllowed`.
    init(choices: PairModelChoices, cloud: CloudPolicy, stt: STTEngineSelector, tts: TTSEngineSelector,
         languagePairManager: LanguagePairManager) {
        self.choices = choices
        self.cloud = cloud
        let currentChoice = { [choices, languagePairManager] in
            choices.choice(for: PairKey(languagePairManager.sourceLanguage, languagePairManager.targetLanguage))
        }
        stt.pairChoice = currentChoice
        tts.pairChoice = currentChoice
        tts.cloudAllowed = { [cloud] in cloud.allowed }
    }
}
