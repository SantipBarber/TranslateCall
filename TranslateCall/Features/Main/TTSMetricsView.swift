import SwiftUI

// MARK: - TTSMetricsView

/// Compact A/B comparison panel shown at the bottom of the main window.
///
/// Displays average synthesis latency for each TTS engine based on the last
/// 100 synthesis events held by `TTSMetricsCollector.shared`.
/// All data is in-memory and resets on app restart.
struct TTSMetricsView: View {

    // MARK: - State

    @State private var avSpeechSummary: TTSMetricsSummary = .empty
    @State private var kokoroSummary: TTSMetricsSummary = .empty
    @State private var voiceCloneSummary: TTSMetricsSummary = .empty
    @State private var isExpanded: Bool = false

    // MARK: - Body

    var body: some View {
        DisclosureGroup(
            isExpanded: $isExpanded,
            content: { metricsGrid },
            label: {
                Label("TTS Performance", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        )
        .task(id: isExpanded) {
            guard isExpanded else { return }
            await refreshMetrics()
        }
    }

    // MARK: - Subviews

    private var metricsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                Text("AVSpeech").font(.caption2).bold().gridColumnAlignment(.center)
                Text("Kokoro").font(.caption2).bold().gridColumnAlignment(.center)
                Text("Voice Clone").font(.caption2).bold().gridColumnAlignment(.center)
            }
            Divider()
            metricRow(
                label: "Avg latency",
                values: [
                    formatLatency(avSpeechSummary),
                    formatLatency(kokoroSummary),
                    formatLatency(voiceCloneSummary)
                ]
            )
            metricRow(
                label: "Utterances",
                values: [
                    "\(avSpeechSummary.count)",
                    "\(kokoroSummary.count)",
                    "\(voiceCloneSummary.count)"
                ]
            )
        }
        .padding(.top, 4)
        .font(.caption)
    }

    @ViewBuilder
    private func metricRow(label: String, values: [String]) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value).monospacedDigit()
            }
        }
    }

    private func formatLatency(_ summary: TTSMetricsSummary) -> String {
        summary.count == 0 ? "—" : "\(Int(summary.avgLatencyMs)) ms"
    }

    // MARK: - Data refresh

    private func refreshMetrics() async {
        avSpeechSummary = await TTSMetricsCollector.shared.summary(for: .avSpeech)
        kokoroSummary = await TTSMetricsCollector.shared.summary(for: .kokoro)
        voiceCloneSummary = await TTSMetricsCollector.shared.summary(for: .voiceClone)
    }
}

// MARK: - Preview

#Preview {
    TTSMetricsView()
        .frame(width: 400)
        .padding()
}
