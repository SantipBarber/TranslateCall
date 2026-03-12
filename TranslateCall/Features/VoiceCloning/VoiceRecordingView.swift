import SwiftUI

struct VoiceRecordingView: View {
    @EnvironmentObject private var profileManager: VoiceProfileManager

    @State private var levels: [Float] = Array(repeating: -60, count: 60)
    @State private var levelTask: Task<Void, Never>?

    private var elapsedSeconds: Float {
        if case .recording(let elapsed) = profileManager.recordingState {
            return elapsed
        }
        return 0
    }

    private var progress: Double {
        Double(min(elapsedSeconds, 30)) / 30.0
    }

    private var timeLabel: String {
        let secs = Int(elapsedSeconds)
        return String(format: "%d:%02d / 0:30", secs / 60, secs % 60)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Record Your Voice")
                .font(.headline)

            Text("Read the transcript aloud in a quiet environment.\nRecording stops automatically at 30 seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

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

            Button("Stop Recording") {
                Task { await profileManager.stopRecording() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .onAppear { startLevelObservation() }
        .onDisappear { levelTask?.cancel() }
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

    // MARK: - Level observation

    private func startLevelObservation() {
        levelTask = Task { @MainActor in
            for await level in profileManager.recorder.levelStream {
                if Task.isCancelled { break }
                levels.append(level)
                if levels.count > 60 {
                    levels.removeFirst(levels.count - 60)
                }
            }
        }
    }
}

#Preview {
    VoiceRecordingView()
        .environmentObject(VoiceProfileManager())
        .frame(width: 400)
}
