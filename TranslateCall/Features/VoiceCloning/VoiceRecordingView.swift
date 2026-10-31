import SwiftUI

struct VoiceRecordingView: View {
    @EnvironmentObject private var profileManager: VoiceProfileManager

    @State private var levels: [Float] = Array(repeating: -60, count: RecordingPanel.levelCount)
    @State private var levelTask: Task<Void, Never>?

    private var elapsedSeconds: Float {
        if case .recording(let elapsed) = profileManager.recordingState {
            return elapsed
        }
        return 0
    }

    var body: some View {
        RecordingPanel(
            mode: profileManager.recordingMode,
            elapsedSeconds: elapsedSeconds,
            levels: levels,
            onStop: { Task { await profileManager.stopRecording() } }
        )
        .onAppear { startLevelObservation() }
        .onDisappear { levelTask?.cancel() }
    }

    private func startLevelObservation() {
        levelTask = Task { @MainActor in
            for await level in profileManager.recorder.levelStream {
                if Task.isCancelled { break }
                levels.append(level)
                if levels.count > RecordingPanel.levelCount {
                    levels.removeFirst(levels.count - RecordingPanel.levelCount)
                }
            }
        }
    }
}

/// The recording screen itself, free of the manager so previews and tests render it from fixtures.
/// Guided mode shows the text to read, large; progress and labels follow `mode.maxSeconds`.
struct RecordingPanel: View {
    static let levelCount = 60

    let mode: RecordingMode
    let elapsedSeconds: Float
    let levels: [Float]
    let onStop: () -> Void

    private var maxSeconds: Int { Int(mode.maxSeconds) }

    private var progress: Double {
        Double(min(Double(elapsedSeconds), mode.maxSeconds) / mode.maxSeconds)
    }

    private var timeLabel: String {
        let secs = Int(elapsedSeconds)
        return String(format: "%d:%02d / %d:%02d", secs / 60, secs % 60, maxSeconds / 60, maxSeconds % 60)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Record Your Voice")
                .font(.headline)

            instructions

            if let text = mode.guidedText {
                guidedTextCard(text)
            }

            // Progress bar
            VStack(spacing: 4) {
                ProgressView(value: progress)
                    .animation(.linear(duration: 0.1), value: progress)

                Text(timeLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Waveform display
            waveformView
                .frame(height: 60)
                .padding(.horizontal, 4)

            // Live quality indicator
            liveLevelBadge

            Button("Stop Recording", action: onStop)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(24)
    }

    private var instructions: some View {
        VStack(spacing: 2) {
            if mode.guidedText == nil {
                Text("Read the transcript aloud in a quiet environment.")
            } else {
                Text("Read the text below aloud in a quiet environment.")
            }
            Text("Recording stops automatically at \(maxSeconds) seconds.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    private func guidedTextCard(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(Theme.Spacing.large)
            .background(Theme.soft(Theme.accent), in: RoundedRectangle(cornerRadius: Theme.Radius.large))
    }

    // MARK: - Waveform

    private var waveformView: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(levels.indices, id: \.self) { idx in
                    let fraction = levelFraction(levels[idx])
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barColor(for: levels[idx]))
                        .frame(
                            width: max(2, (geo.size.width - CGFloat(levels.count)) / CGFloat(levels.count)),
                            height: max(2, geo.size.height * fraction)
                        )
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func levelFraction(_ dbfs: Float) -> Double {
        let clamped = max(-60, min(0, dbfs))
        return Double((clamped + 60) / 60)
    }

    private func barColor(for dbfs: Float) -> Color {
        if dbfs >= -3 { return .red }
        if dbfs >= -12 { return .yellow }
        return .green
    }

    // MARK: - Live level badge

    private var liveLevelBadge: some View {
        let currentLevel = levels.last ?? -60
        let label: String
        let color: Color
        if currentLevel >= -3 {
            label = "Too loud"
            color = .red
        } else if currentLevel >= -20 {
            label = "Good level"
            color = .green
        } else if currentLevel >= -40 {
            label = "Low level"
            color = .yellow
        } else {
            label = "Very quiet"
            color = .secondary
        }

        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Guided, light") { RecordingPanel.guidedFixture().preferredColorScheme(.light) }
#Preview("Guided, dark") { RecordingPanel.guidedFixture().preferredColorScheme(.dark) }
#Preview("Free") {
    RecordingPanel(mode: .free, elapsedSeconds: 12, levels: RecordingPanel.fixtureLevels, onStop: {})
        .frame(width: 440)
}

extension RecordingPanel {
    static let fixtureLevels: [Float] = (0 ..< levelCount).map { -45 + Float($0 % 9) * 4 }

    static func guidedFixture(language: String = "spanish") -> some View {
        RecordingPanel(mode: .guided(language: language), elapsedSeconds: 5, levels: fixtureLevels, onStop: {})
            .frame(width: 440)
    }
}
