import Foundation

// MARK: - TTSMetrics

/// Synthesis performance record for one utterance.
nonisolated struct TTSMetrics: Sendable {
    let engine: TTSEngine
    /// Wall-clock milliseconds from `speak()` call to first audio sample scheduled.
    let synthesisLatencyMs: Int
    /// Character count of the input text.
    let textLength: Int
    let locale: Locale
    let timestamp: Date
}

// MARK: - TTSMetricsSummary

/// Aggregated TTS performance summary for one engine.
nonisolated struct TTSMetricsSummary: Sendable, Equatable {
    let avgLatencyMs: Double
    let count: Int

    nonisolated static let empty = TTSMetricsSummary(avgLatencyMs: 0, count: 0)
}
