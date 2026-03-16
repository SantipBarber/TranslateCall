import SwiftUI

struct VoiceTranscriptView: View {
    @EnvironmentObject private var profileManager: VoiceProfileManager

    let result: RecordingResult

    @State private var profileName: String = ""
    @State private var transcript: String = ""

    private let maxTranscriptLength = 2000

    private var isSaveBlocked: Bool {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isQualityBlocked
    }

    private var isQualityBlocked: Bool {
        result.quality.grade == .poor && result.quality.voicedDurationSeconds < 8
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Review & Save")
                .font(.headline)

            // Quality summary row
            qualitySummaryRow

            // Quality warnings
            qualityWarnings

            Divider()

            // Profile name
            HStack {
                Text("Name:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("My Voice", text: $profileName)
                    .textFieldStyle(.roundedBorder)
            }

            // Transcript entry
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcript (required)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $transcript)
                    .font(.body)
                    .frame(minHeight: 80, maxHeight: 120)
                    .border(Color.secondary.opacity(0.3), width: 1)
                    .onChange(of: transcript) { _, newValue in
                        if newValue.count > maxTranscriptLength {
                            transcript = String(newValue.prefix(maxTranscriptLength))
                        }
                    }
                HStack {
                    Text("\(transcript.count)/\(maxTranscriptLength)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Transcript is required to save")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                Button("Re-record") {
                    profileManager.discardAndReRecord()
                }
                .buttonStyle(.bordered)

                Spacer()

                if case .saving = profileManager.recordingState {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Save Profile") {
                        Task {
                            try? await profileManager.saveProfile(
                                name: profileName,
                                transcript: transcript,
                                result: result
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaveBlocked)
                }
            }
        }
        .padding(24)
    }

    // MARK: - Quality summary

    private var qualitySummaryRow: some View {
        HStack(spacing: 16) {
            qualityItem(
                label: "Duration",
                value: String(format: "%.1f s", result.durationSeconds)
            )
            qualityItem(
                label: "Peak RMS",
                value: String(format: "%.0f dBFS", result.quality.peakRmsDbfs)
            )
            qualityItem(
                label: "Voiced",
                value: String(format: "%.0f s", result.quality.voicedDurationSeconds)
            )
            qualityItem(
                label: "Grade",
                value: result.quality.grade.rawValue.capitalized,
                color: gradeColor
            )
        }
    }

    private func qualityItem(
        label: String, value: String, color: Color = .primary
    ) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var gradeColor: Color {
        switch result.quality.grade {
        case .good: return .green
        case .fair: return .yellow
        case .poor: return .red
        }
    }

    // MARK: - Quality warnings

    @ViewBuilder
    private var qualityWarnings: some View {
        if isQualityBlocked {
            warningBanner(
                "Insufficient speech detected "
                    + "(\(String(format: "%.0f", result.quality.voicedDurationSeconds))s voiced). "
                    + "Please re-record with more speech.",
                severity: .critical
            )
        } else if result.quality.hasClipping {
            warningBanner(
                "Recording contains clipping. Move further from the microphone and re-record.",
                severity: .warning
            )
        } else if result.quality.peakRmsDbfs < -30 {
            warningBanner(
                "Recording level is very low. Move closer to the microphone and re-record.",
                severity: .warning
            )
        } else if result.quality.grade == .fair {
            warningBanner(
                "Recording quality is acceptable but could be improved with a quieter environment.",
                severity: .info
            )
        }
    }

    private enum WarningSeverity {
        case critical, warning, info
    }

    private func warningBanner(_ message: String, severity: WarningSeverity) -> some View {
        let icon: String
        let color: Color
        switch severity {
        case .critical:
            icon = "exclamationmark.triangle.fill"
            color = .red
        case .warning:
            icon = "exclamationmark.triangle"
            color = .yellow
        case .info:
            icon = "info.circle"
            color = .blue
        }

        return HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(color.opacity(0.1))
        .cornerRadius(6)
    }
}

#Preview {
    VoiceTranscriptView(
        result: RecordingResult(
            samples: Array(repeating: 0.5, count: 24000),
            durationSeconds: 25.0,
            quality: VoiceQualityMetrics(
                peakRmsDbfs: -18,
                hasClipping: false,
                voicedDurationSeconds: 22.0,
                grade: .good
            )
        )
    )
    .environmentObject(VoiceProfileManager())
    .frame(width: 400)
}
