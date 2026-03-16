import Foundation

// MARK: - STTMetricsSummary

/// Aggregated statistics for one STT engine, returned by `STTMetricsCollector.summary(for:)`.
struct STTMetricsSummary {
    let avgLatencyMs: Double
    let avgConfidence: Double
    let count: Int

    /// Convenience constant for "no data" state.
    nonisolated static let empty = STTMetricsSummary(avgLatencyMs: 0, avgConfidence: 0, count: 0)
}

// MARK: - STTMetrics

/// Captures timing and quality data for a single STT transcription event.
///
/// Used by `STTMetricsCollector` to power the A/B comparison panel.
/// All values are immutable after creation.
struct STTMetrics: Sendable {
    /// Which engine produced this result.
    let engine: STTEngine
    /// Duration of the audio segment submitted to STT, in milliseconds.
    let segmentDurationMs: Int
    /// Wall-clock time from segment submission to `TranscriptionResult` emission, in milliseconds.
    let transcriptionLatencyMs: Int
    /// Mean word-level confidence of the transcription result (0.0 – 1.0).
    let confidence: Float
    /// Character count of the transcribed text (proxy for segment richness).
    let textLength: Int
    /// Wall-clock timestamp of the transcription event.
    let timestamp: Date
}
