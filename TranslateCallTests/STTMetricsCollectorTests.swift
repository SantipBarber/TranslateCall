import Foundation
import Testing
@testable import TranslateCall

// MARK: - STTMetricsCollectorTests

/// Tests for `STTMetricsCollector`.
///
/// Uses isolated `STTMetricsCollector(cap:)` instances rather than `.shared`
/// so tests do not affect each other.
@Suite("STTMetricsCollector")
@MainActor
struct STTMetricsCollectorTests {

    // MARK: - Helpers

    func makeMetrics(
        engine: STTEngine = .appleSpeech,
        latencyMs: Int = 300,
        confidence: Float = 0.85
    ) -> STTMetrics {
        STTMetrics(
            engine: engine,
            segmentDurationMs: 2000,
            transcriptionLatencyMs: latencyMs,
            confidence: confidence,
            textLength: 20,
            timestamp: .now
        )
    }

    // MARK: - record

    @Test("Record single entry — count is 1")
    func recordSingleEntry() async {
        let collector = STTMetricsCollector(cap: 100)
        await collector.record(makeMetrics())
        let count = await collector.recent.count
        #expect(count == 1)
    }

    @Test("Record multiple entries — all present up to cap")
    func recordMultipleEntries() async {
        let collector = STTMetricsCollector(cap: 100)
        for _ in 0..<10 {
            await collector.record(makeMetrics())
        }
        let count = await collector.recent.count
        #expect(count == 10)
    }

    // MARK: - Cap enforcement

    @Test("Does not exceed cap — oldest dropped")
    func doesNotExceedCap() async {
        let cap = 5
        let collector = STTMetricsCollector(cap: cap)
        for i in 0..<10 {
            // Use latency as a unique identifier
            await collector.record(makeMetrics(latencyMs: i * 10))
        }
        let entries = await collector.recent
        #expect(entries.count == cap)
        // Oldest (latency 0..49) dropped; newest retained (latency 50..90)
        #expect(entries.first?.transcriptionLatencyMs == 50)
        #expect(entries.last?.transcriptionLatencyMs == 90)
    }

    @Test("Cap of 100 works correctly")
    func cap100() async {
        let collector = STTMetricsCollector(cap: 100)
        for _ in 0..<110 {
            await collector.record(makeMetrics())
        }
        let count = await collector.recent.count
        #expect(count == 100)
    }

    // MARK: - summary

    @Test("Summary for empty collector returns zeros")
    func summaryEmptyCollector() async {
        let collector = STTMetricsCollector(cap: 100)
        let summary = await collector.summary(for: .parakeet)
        #expect(summary.avgLatencyMs == 0)
        #expect(summary.avgConfidence == 0)
        #expect(summary.count == 0)
    }

    @Test("Summary for engine with no entries returns zeros")
    func summaryWrongEngine() async {
        let collector = STTMetricsCollector(cap: 100)
        await collector.record(makeMetrics(engine: .appleSpeech))
        let summary = await collector.summary(for: .parakeet)
        #expect(summary.count == 0)
    }

    @Test("Summary computes correct average latency")
    func summaryAverageLatency() async {
        let collector = STTMetricsCollector(cap: 100)
        await collector.record(makeMetrics(engine: .parakeet, latencyMs: 200))
        await collector.record(makeMetrics(engine: .parakeet, latencyMs: 400))
        let summary = await collector.summary(for: .parakeet)
        #expect(summary.count == 2)
        #expect(abs(summary.avgLatencyMs - 300) < 0.001) // avg of 200 and 400
    }

    @Test("Summary computes correct average confidence")
    func summaryAverageConfidence() async {
        let collector = STTMetricsCollector(cap: 100)
        await collector.record(makeMetrics(engine: .parakeet, confidence: 0.8))
        await collector.record(makeMetrics(engine: .parakeet, confidence: 1.0))
        let summary = await collector.summary(for: .parakeet)
        #expect(abs(summary.avgConfidence - 0.9) < 0.001) // avg of 0.8 and 1.0
    }

    @Test("Summary only includes entries for the requested engine")
    func summaryFiltersByEngine() async {
        let collector = STTMetricsCollector(cap: 100)
        await collector.record(makeMetrics(engine: .appleSpeech, latencyMs: 500))
        await collector.record(makeMetrics(engine: .parakeet, latencyMs: 200))
        let appleSummary = await collector.summary(for: .appleSpeech)
        let parakeetSummary = await collector.summary(for: .parakeet)
        #expect(appleSummary.count == 1)
        #expect(parakeetSummary.count == 1)
        #expect(abs(appleSummary.avgLatencyMs - 500) < 0.001)
        #expect(abs(parakeetSummary.avgLatencyMs - 200) < 0.001)
    }

    // MARK: - reset

    @Test("Reset clears all entries")
    func resetClearsAll() async {
        let collector = STTMetricsCollector(cap: 100)
        await collector.record(makeMetrics())
        await collector.record(makeMetrics(engine: .parakeet))
        await collector.reset()
        let count = await collector.recent.count
        #expect(count == 0)
    }

    @Test("Summary returns zeros after reset")
    func summaryAfterReset() async {
        let collector = STTMetricsCollector(cap: 100)
        await collector.record(makeMetrics(engine: .parakeet, latencyMs: 400))
        await collector.reset()
        let summary = await collector.summary(for: .parakeet)
        #expect(summary.count == 0)
    }
}
