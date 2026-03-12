import Foundation
import OSLog

// nonisolated(unsafe): file-level logger used from actor context; Logger is Sendable — safe
nonisolated(unsafe) private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TTSMetricsCollector")

// MARK: - TTSMetricsCollector

/// In-memory ring buffer of TTS performance metrics.
///
/// Mirrors `STTMetricsCollector` exactly. Metrics are never persisted to disk.
actor TTSMetricsCollector {

    // MARK: - Singleton

    static let shared = TTSMetricsCollector()

    // MARK: - Storage

    private(set) var recent: [TTSMetrics] = []
    private let cap: Int

    // MARK: - Init

    /// `cap` is injectable so unit tests can use a small ring buffer without touching `.shared`.
    init(cap: Int = 100) {
        self.cap = cap
    }

    // MARK: - Public API

    func record(_ metrics: TTSMetrics) {
        recent.append(metrics)
        if recent.count > cap { recent.removeFirst() }
    }

    func summary(for engine: TTSEngine) -> TTSMetricsSummary {
        let filtered = recent.filter { $0.engine == engine }
        guard !filtered.isEmpty else { return .empty }
        let avgLatency = Double(filtered.map(\.synthesisLatencyMs).reduce(0, +)) / Double(filtered.count)
        return TTSMetricsSummary(avgLatencyMs: avgLatency, count: filtered.count)
    }

    func reset() {
        recent.removeAll()
        logger.debug("TTSMetricsCollector reset")
    }
}
