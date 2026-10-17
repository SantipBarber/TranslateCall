import SwiftUI

// MARK: - STTMetricsView

/// Compact A/B comparison panel shown at the bottom of the main window.
///
/// Displays average latency and confidence for each STT engine based on the last
/// 100 transcription events held by `STTMetricsCollector.shared`.
/// All data is in-memory and resets on app restart.
struct STTMetricsView: View {

    // MARK: - State

    @State private var appleSummary: STTMetricsSummary = .empty
    @State private var parakeetSummary: STTMetricsSummary = .empty
    @State private var whisperSummary: STTMetricsSummary = .empty
    @State private var isExpanded: Bool = false

    // MARK: - Body

    var body: some View {
        DisclosureGroup(
            isExpanded: $isExpanded,
            content: { metricsGrid },
            label: {
                Label("STT Performance", systemImage: "chart.bar")
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
                Text("Apple Speech").font(.caption).bold()
                    .gridColumnAlignment(.center)
                Text("Parakeet").font(.caption).bold()
                    .gridColumnAlignment(.center)
                Text("Whisper").font(.caption).bold()
                    .gridColumnAlignment(.center)
            }
            Divider()
            metricRow(
                label: "Avg latency",
                values: [appleSummary, parakeetSummary, whisperSummary]
                    .map { $0.count == 0 ? "—" : "\(Int($0.avgLatencyMs)) ms" }
            )
            metricRow(
                label: "Avg confidence",
                values: [appleSummary, parakeetSummary, whisperSummary]
                    .map { $0.count == 0 ? "—" : String(format: "%.2f", $0.avgConfidence) }
            )
            metricRow(
                label: "Segments",
                values: [appleSummary, parakeetSummary, whisperSummary]
                    .map { "\($0.count)" }
            )
        }
        .padding(.top, 4)
        .font(.caption)
    }

    @ViewBuilder
    private func metricRow(label: String, values: [String]) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            ForEach(values.indices, id: \.self) { idx in
                Text(values[idx]).monospacedDigit()
            }
        }
    }

    // MARK: - Data refresh

    private func refreshMetrics() async {
        appleSummary = await STTMetricsCollector.shared.summary(for: .appleSpeech)
        parakeetSummary = await STTMetricsCollector.shared.summary(for: .parakeet)
        whisperSummary = await STTMetricsCollector.shared.summary(for: .whisper)
    }
}

// MARK: - Preview

#Preview {
    STTMetricsView()
        .frame(width: 500)
        .padding()
}
