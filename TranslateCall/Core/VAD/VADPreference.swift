import Foundation

/// "Voice detector" in Settings › Advanced (REQ-ST-33): Silero (default) or Basic (energy).
@MainActor
enum VADPreference {
    static let key = "tlk.vad.engine"

    static func engine(in defaults: UserDefaults = .standard) -> VADEngine {
        defaults.string(forKey: key) == "energy" ? .energy : .silero
    }

    static func set(_ engine: VADEngine, in defaults: UserDefaults = .standard) {
        defaults.set(engine == .energy ? "energy" : "silero", forKey: key)
    }
}
