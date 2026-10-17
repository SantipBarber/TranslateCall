import Foundation
import Testing
@testable import TranslateCall

/// M9 design §3.6 measure-first gate: how long one PR-set clip takes through the real pipeline,
/// and how much total latency moves between two identical runs (NFR-BH-01, NFR-BH-02).
/// Writes build/bench/measure-first.json. Throwaway: removed once the full runner lands (Task 6).
extension BenchTests {
    @Suite("Measure first") @MainActor
    struct MeasureFirstTests {
        static let prClips = 56            // 4 Basic + 3 Best run lines × 8 clips (design §3.6)
        static let prSessions = 7
        static let prMTSentences = 400     // 2 directions × 200 (REQ-BH-08)
        static let meanPRClipSeconds = 5.0 // PR clips are chosen ≤ 6 s

        struct Run { var totalsMs: [Double] = []; var clipOverheads: [Double] = []; var sessionStart: Double = 0 }

        @Test func prDurationAndVariance() async throws {
            try await requireSpeechAuthorization()
            try await requireTranslationPack(from: "es", to: "en")
            try await requireTranslationPack(from: "en", to: "es")
            let fixtures = try Fixtures.lang("es")
            let first = try await run(fixtures, repeats: 2)
            let second = try await run(fixtures, repeats: 2)
            let mtMs = try await mtOnlyMs()

            let (medianA, medianB) = (median(first.totalsMs), median(second.totalsMs))
            let variance = abs(medianA - medianB) / ((medianA + medianB) / 2)
            let overhead = median(first.clipOverheads + second.clipOverheads)
            let projected = Double(Self.prClips) * (Self.meanPRClipSeconds + overhead)
                + Double(Self.prSessions) * first.sessionStart
                + Double(Self.prMTSentences) * mtMs / 1000
            let report: [String: Double] = [
                "medianTotalRunA_ms": medianA, "medianTotalRunB_ms": medianB, "variance": variance,
                "clipOverhead_s": overhead, "sessionStart_s": first.sessionStart, "mtOnly_ms": mtMs,
                "projectedPR_s": projected,
            ]
            try write(report)
            print("BENCH-GATE \(report.sorted { $0.key < $1.key })")
            #expect(projected <= 600, "PR bench projected at \(Int(projected)) s > 10 min — STOP, see tasks.md Task 1")
            #expect(variance <= 0.05, "run-to-run total p50 moved \(Int(variance * 100)) % > 5 % — STOP")
        }

        private func run(_ fixtures: [AudioFixture], repeats: Int) async throws -> Run {
            let options = BenchOptions()
            let session = try await BenchPipelineFactory.make(.outgoingEsESToEn, options: options)
            let log = session.output
            var result = Run()
            let started = ContinuousClock.now
            try await BenchPipelineFactory.start(session, options: options)
            await session.player.playSilence(seconds: 2)   // translation warm-up (REQ-TR-05)
            result.sessionStart = started.duration(to: .now).milliseconds / 1000
            for fixture in Array(repeating: fixtures, count: repeats).flatMap({ $0 }) {
                let samples = try FileAudioSource.decode16kMono(Fixtures.url(for: fixture))
                print("BENCH-CLIP start \(fixture.id) \(Date())")
                let feed = await session.player.play(samples)
                print("BENCH-CLIP fed \(fixture.id) \(Date())")
                let speechEnd = feed.instant(ofSample: Self.lastLoudSample(samples))
                let heard = await waitUntil(timeout: .seconds(15)) { log.scheduleTimes.contains { $0 > speechEnd } }
                try requirePrerequisite(heard, "TTS audio for \(fixture.id) within 15 s")
                await session.player.playSilence(seconds: 1.0)   // let synthesis finish, then the gap
                await session.player.playSilence(seconds: 0.5)
                if let firstBuffer = log.scheduleTimes.first(where: { $0 > speechEnd }) {
                    result.totalsMs.append(speechEnd.duration(to: firstBuffer).milliseconds)
                }
                let audioSeconds = Double(samples.count) / BenchClipPlayer.sampleRate
                result.clipOverheads.append(feed.start.duration(to: .now).milliseconds / 1000 - audioSeconds)
            }
            await session.tearDown()
            return result
        }

        /// Median ms of a direct Apple translation, the MT-only set's per-sentence cost (REQ-BH-08).
        private func mtOnlyMs() async throws -> Double {
            let (model, host) = hostTranslationBridge()
            defer { host.close() }
            let service = AppleTranslationService(model: model)
            let (es, en) = (Locale.Language(identifier: "es"), Locale.Language(identifier: "en"))
            _ = try await service.translate(text: "Hola", from: es, to: en)   // load the model
            var times: [Double] = []
            for sentence in ["La reunión empieza a las diez.", "Necesitamos revisar el presupuesto antes del viernes.",
                             "¿Me oyes bien?", "Mañana te envío el informe completo con los números."] {
                let start = ContinuousClock.now
                _ = try await service.translate(text: sentence, from: es, to: en)
                times.append(start.duration(to: .now).milliseconds)
            }
            return median(times)
        }

        /// Last sample above 1 % of full scale: the end of speech in a `say` fixture (crude, gate only).
        static func lastLoudSample(_ samples: [Float]) -> Int {
            samples.lastIndex { abs($0) > 0.01 } ?? samples.count - 1
        }

        private func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            return sorted.count.isMultiple(of: 2)
                ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
        }

        private func write(_ report: [String: Double]) throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let dir = root.appendingPathComponent("build/bench")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: dir.appendingPathComponent("measure-first.json"))
        }
    }
}

