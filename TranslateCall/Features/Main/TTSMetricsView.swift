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
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                Text("AVSpeech").font(.caption).bold().gridColumnAlignment(.center)
                Text("Kokoro").font(.caption).bold().gridColumnAlignment(.center)
            }
            Divider()
            metricRow(
                label: "Avg latency",
                avValue: avSpeechSummary.count == 0 ? "—" : "\(Int(avSpeechSummary.avgLatencyMs)) ms",
                kokoroValue: kokoroSummary.count == 0 ? "—" : "\(Int(kokoroSummary.avgLatencyMs)) ms"
            )
            metricRow(
                label: "Utterances",
                avValue: "\(avSpeechSummary.count)",
                kokoroValue: "\(kokoroSummary.count)"
            )
        }
        .padding(.top, 4)
        .font(.caption)
    }

    @ViewBuilder
    private func metricRow(label: String, avValue: String, kokoroValue: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(avValue).monospacedDigit()
            Text(kokoroValue).monospacedDigit()
        }
    }

    // MARK: - Data refresh

    private func refreshMetrics() async {
        avSpeechSummary = await TTSMetricsCollector.shared.summary(for: .avSpeech)
        kokoroSummary = await TTSMetricsCollector.shared.summary(for: .kokoro)
    }
}

// MARK: - Preview

#Preview {
    TTSMetricsView()
        .frame(width: 400)
        .padding()
}
