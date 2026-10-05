import Combine
import Foundation

/// The user's conversation settings (F8.5.3 REQ-H-01, REQ-V-05), persisted in `UserDefaults`.
///
/// `listeningMode` is applied live (the coordinator forwards it to the mic echo gate);
/// `pauseSeconds` is read when a session starts (the VAD fixes its configuration on activation).
@MainActor
final class ConversationSettings: ObservableObject {
    nonisolated static let listeningModeKey = "conversation.listeningMode"
    nonisolated static let pauseSecondsKey = "conversation.pauseSeconds"
    nonisolated static let pauseRange: ClosedRange<Double> = 0.4...1.2
    /// Slider step: tenths of a second.
    nonisolated static let pauseStep = 0.1
    nonisolated static let defaultPauseSeconds = 0.6

    @Published var listeningMode: ListeningMode {
        didSet { defaults.set(listeningMode.rawValue, forKey: Self.listeningModeKey) }
    }

    /// "Pause to translate", in seconds: clamped to `pauseRange` and rounded to `pauseStep`.
    @Published var pauseSeconds: Double {
        didSet {
            let clamped = Self.clampedPause(pauseSeconds)
            if clamped != pauseSeconds {
                pauseSeconds = clamped   // re-assignment inside didSet does not call didSet again
            }
            defaults.set(pauseSeconds, forKey: Self.pauseSecondsKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        listeningMode = defaults.string(forKey: Self.listeningModeKey).flatMap(ListeningMode.init(rawValue:))
            ?? .headphones
        pauseSeconds = (defaults.object(forKey: Self.pauseSecondsKey) as? Double).map(Self.clampedPause)
            ?? Self.defaultPauseSeconds
    }

    /// The VAD configuration for the next session (REQ-V-05), already validated (REQ-V-06).
    var vadConfiguration: VADConfiguration {
        var config = VADConfiguration()
        config.minSilenceDuration = pauseSeconds
        return config.validated()
    }

    nonisolated static func clampedPause(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return defaultPauseSeconds }
        let clamped = min(max(seconds, pauseRange.lowerBound), pauseRange.upperBound)
        return (clamped * 10).rounded() / 10   // tenths, without 0.1's binary rounding error
    }
}
