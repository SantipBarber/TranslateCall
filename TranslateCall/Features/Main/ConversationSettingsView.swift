import SwiftUI

/// "I use speakers", "Pause to translate", the active VAD engine and the usage guide
/// (F8.5.3 REQ-H-01, REQ-V-03, REQ-V-05, REQ-U-02).
struct ConversationSettingsView: View {
    @ObservedObject var settings: ConversationSettings
    @ObservedObject var vadProvider: VADProvider
    var isCapturing: Bool

    /// The usage guide on the repository's main branch (REQ-U-01).
    static let guideURL = URL(string: "https://github.com/SantipBarber/TranslateCall/blob/main/docs/usage-guide.md")

    /// "VAD: Silero" / "VAD: Energy" / "VAD: —" before the first session.
    nonisolated static func vadLabel(_ engine: VADEngine?) -> String {
        switch engine {
        case .silero: return "VAD: Silero"
        case .energy: return "VAD: Energy"
        case nil: return "VAD: —"
        }
    }

    nonisolated static func pauseLabel(_ seconds: Double) -> String {
        "Pause to translate: " + String(format: "%.1f s", seconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: speakersBinding) {
                    Label("I use speakers", systemImage: "speaker.wave.2")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Turn on if the translation plays through speakers: the mic pauses while it plays")

                Spacer()

                Text(Self.vadLabel(vadProvider.activeEngine))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let url = Self.guideURL {
                    Link("Usage guide", destination: url)
                        .font(.caption)
                }
            }
            HStack(spacing: 8) {
                Text(Self.pauseLabel(settings.pauseSeconds))
                    .font(.caption)
                    .monospacedDigit()
                Slider(value: $settings.pauseSeconds,
                       in: ConversationSettings.pauseRange,
                       step: ConversationSettings.pauseStep)
                    .controlSize(.mini)
                if isCapturing {
                    Text("Applies to the next session")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var speakersBinding: Binding<Bool> {
        Binding(
            get: { settings.listeningMode == .speakers },
            set: { settings.listeningMode = $0 ? .speakers : .headphones }
        )
    }
}
