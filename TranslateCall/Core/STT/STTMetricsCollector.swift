import Foundation

// MARK: - STTMetricsCollector

/// Actor that accumulates `STTMetrics` for the A/B comparison panel.
///
/// All data is in-memory only — cleared on app restart (no persistence to disk).
/// The singleton `shared` is used by both `ParakeetSpeechService` and `AppleSpeechService`
/// so every transcription event is captured regardless of active engine.
actor STTMetricsCollector {

    // MARK: - Singleton

    static let shared = STTMetricsCollector()

    // MARK: - State

    /// Bounded ring buffer of recent metrics; older entries are dropped when cap is reached.
    private(set) var recent: [STTMetrics] = []

    /// Maximum number of entries retained. Oldest entries are discarded beyond this limit.
    private let cap: Int

    // MARK: - Init

    /// `cap` is exposed for testing (default 100 matches REQ-PAR-22).
    init(cap: Int = 100) {
        self.cap = cap
    }

    // MARK: - Public API

    /// Record a new metrics entry. Drops the oldest entry when the cap is reached.
    func record(_ metrics: STTMetrics) {
        recent.append(metrics)
        if recent.count > cap {
            recent.removeFirst()
        }
    }

    /// Aggregated statistics for a specific engine.
    ///
    /// Returns `STTMetricsSummary.empty` when no entries exist for `engine`.
    func summary(for engine: STTEngine) -> STTMetricsSummary {
        let filtered = recent.filter { $0.engine == engine }
        guard !filtered.isEmpty else { return .empty }
        let count = filtered.count
        let totalLatency = filtered.reduce(0.0) { $0 + Double($1.transcriptionLatencyMs) }
        let totalConfidence = filtered.reduce(0.0) { $0 + Double($1.confidence) }
        return STTMetricsSummary(
            avgLatencyMs: totalLatency / Double(count),
            avgConfidence: totalConfidence / Double(count),
            count: count
        )
    }

    /// Removes all recorded entries. Primarily used in tests to reset shared state.
    func reset() {
        recent.removeAll()
    }
}
