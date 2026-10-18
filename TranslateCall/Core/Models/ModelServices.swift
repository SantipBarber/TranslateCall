import Combine
import Foundation

// MARK: - ModelServices

/// The per-pair model choices, the cloud policy and the downloads, wired into both selectors (M9 UI
/// settings P1, P20, S-4). Lives in `UIServices`.
@MainActor
struct ModelServices {
    let choices: PairModelChoices
    let cloud: CloudPolicy
    let downloads: ModelDownloads

    /// Production: the stores in `UserDefaults.standard` and the machine-wide Edge consent.
    /// `sessionActive` is for the downloads, which must not start during a call (S-7).
    init(stt: STTEngineSelector, tts: TTSEngineSelector, languagePairManager: LanguagePairManager,
         sessionActive: AnyPublisher<Bool, Never>) {
        self.init(choices: PairModelChoices(), cloud: CloudPolicy(),
                  downloads: ModelDownloads(probe: .live, sessionActive: sessionActive),
                  stt: stt, tts: tts, languagePairManager: languagePairManager)
    }

    /// Injected (tests): wires `pairChoice` of both selectors to the current pair, `cloudAllowed`, and
    /// "Use my voice" to the downloads.
    init(choices: PairModelChoices, cloud: CloudPolicy, downloads: ModelDownloads, stt: STTEngineSelector,
         tts: TTSEngineSelector, languagePairManager: LanguagePairManager) {
        self.choices = choices
        self.cloud = cloud
        self.downloads = downloads
        let currentChoice = { [choices, languagePairManager] in
            choices.choice(for: PairKey(languagePairManager.sourceLanguage, languagePairManager.targetLanguage))
        }
        stt.pairChoice = currentChoice
        tts.pairChoice = currentChoice
        tts.cloudAllowed = { [cloud] in cloud.allowed }
        tts.startVoiceCloneDownload = { [downloads] in downloads.start(.voiceClone) }
        tts.downloadsBlocked = { [downloads] in downloads.isBlocked }
    }

    /// What re-runs the preloader besides a pair change (REQ-ST-61): a pair's choice, the cloud policy, a
    /// finished download, "Use my voice" and its profile.
    func preloadTriggers(tts: TTSEngineSelector) -> [AnyPublisher<Void, Never>] {
        [choices.$all.map { _ in () }.eraseToAnyPublisher(),
         cloud.$allowed.map { _ in () }.eraseToAnyPublisher(),
         downloads.didFinish.map { _ in () }.eraseToAnyPublisher(),
         tts.$voiceCloningEnabled.map { _ in () }.eraseToAnyPublisher(),
         tts.$activeVoiceProfileId.map { _ in () }.eraseToAnyPublisher()]
    }
}
