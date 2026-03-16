import Foundation

// MARK: - KokoroConfiguration

/// Configuration for the Kokoro TTS engine.
struct KokoroConfiguration: Sendable {
    /// Kokoro voice identifier (e.g. "af_heart", "am_adam").
    /// Empty string → `TtsConstants.recommendedVoice` ("af_heart").
    var voiceIdentifier: String = ""

    /// UserDefaults key for persisting voice selection.
    static let voiceDefaultsKey = "tlk.tts.kokoro.voice"

    nonisolated static let `default` = KokoroConfiguration()
}
