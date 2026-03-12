import Foundation
import Testing
@testable import TranslateCall

// MARK: - TTSMetricsCollectorTests

/// Tests for `TTSMetricsCollector`.
///
/// Uses isolated `TTSMetricsCollector(cap:)` instances rather than `.shared`
/// so tests do not affect each other.
@Suite("TTSMetricsCollector")
@MainActor
struct TTSMetricsCollectorTests {

    // MARK: - Helpers

    func makeMetrics(
        engine: TTSEngine = .avSpeech,
        latencyMs: Int = 150,
        textLength: Int = 20
    ) -> TTSMetrics {
        TTSMetrics(
            engine: engine,
            synthesisLatencyMs: latencyMs,
            textLength: textLength,
            locale: Locale(identifier: "en-US"),
            timestamp: .now
        )
    }

    // MARK: - record

    @Test("Record single entry — count is 1")
    func recordSingleEntry() async {
        let collector = TTSMetricsCollector(cap: 100)
        await collector.record(makeMetrics())
        let count = await collector.recent.count
        #expect(count == 1)
    }

    @Test("Record multiple entries — all present up to cap")
    func recordMultipleEntries() async {
        let collector = TTSMetricsCollector(cap: 100)
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
        let collector = TTSMetricsCollector(cap: cap)
        for i in 0..<10 {
            await collector.record(makeMetrics(latencyMs: i * 10))
        }
        let entries = await collector.recent
        #expect(entries.count == cap)
        #expect(entries.first?.synthesisLatencyMs == 50)
        #expect(entries.last?.synthesisLatencyMs == 90)
    }

    @Test("Cap of 100 works correctly")
    func cap100() async {
        let collector = TTSMetricsCollector(cap: 100)
        for _ in 0..<110 {
            await collector.record(makeMetrics())
        }
        let count = await collector.recent.count
        #expect(count == 100)
    }

    // MARK: - summary

    @Test("Summary for empty collector returns zeros")
    func summaryEmptyCollector() async {
        let collector = TTSMetricsCollector(cap: 100)
        let summary = await collector.summary(for: .kokoro)
        #expect(summary.avgLatencyMs == 0)
        #expect(summary.count == 0)
    }

    @Test("Summary for engine with no entries returns zeros")
    func summaryWrongEngine() async {
        let collector = TTSMetricsCollector(cap: 100)
        await collector.record(makeMetrics(engine: .avSpeech))
        let summary = await collector.summary(for: .kokoro)
        #expect(summary.count == 0)
    }

    @Test("Summary computes correct average latency")
    func summaryAverageLatency() async {
        let collector = TTSMetricsCollector(cap: 100)
        await collector.record(makeMetrics(engine: .kokoro, latencyMs: 100))
        await collector.record(makeMetrics(engine: .kokoro, latencyMs: 300))
        let summary = await collector.summary(for: .kokoro)
        #expect(summary.count == 2)
        #expect(abs(summary.avgLatencyMs - 200) < 0.001) // avg of 100 and 300
    }

    @Test("Summary only includes entries for the requested engine")
    func summaryFiltersByEngine() async {
        let collector = TTSMetricsCollector(cap: 100)
        await collector.record(makeMetrics(engine: .avSpeech, latencyMs: 120))
        await collector.record(makeMetrics(engine: .kokoro, latencyMs: 250))
        let avSummary = await collector.summary(for: .avSpeech)
        let kokoroSummary = await collector.summary(for: .kokoro)
        #expect(avSummary.count == 1)
        #expect(kokoroSummary.count == 1)
        #expect(abs(avSummary.avgLatencyMs - 120) < 0.001)
        #expect(abs(kokoroSummary.avgLatencyMs - 250) < 0.001)
    }

    // MARK: - reset

    @Test("Reset clears all entries")
    func resetClearsAll() async {
        let collector = TTSMetricsCollector(cap: 100)
        await collector.record(makeMetrics())
        await collector.record(makeMetrics(engine: .kokoro))
        await collector.reset()
        let count = await collector.recent.count
        #expect(count == 0)
    }

    @Test("Summary returns zeros after reset")
    func summaryAfterReset() async {
        let collector = TTSMetricsCollector(cap: 100)
        await collector.record(makeMetrics(engine: .kokoro, latencyMs: 200))
        await collector.reset()
        let summary = await collector.summary(for: .kokoro)
        #expect(summary.count == 0)
    }

    // MARK: - TTSMetricsSummary.empty

    @Test("TTSMetricsSummary.empty has zero values")
    func summaryEmptyValues() {
        let empty = TTSMetricsSummary.empty
        #expect(empty.avgLatencyMs == 0)
        #expect(empty.count == 0)
    }
}
