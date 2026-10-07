import AppKit
import Foundation
import Testing
@testable import TranslateCall

extension IntegrationTests {
    /// The production path (F8.5.4): `AppleTranslationService` → `TranslationBridgeModel` →
    /// `TranslationHostWindow`, with the session kept open between sentences.
    @Suite("Translation bridge (kept session)", .serialized) @MainActor
    struct TranslationBridgeIntegrationTests {
        @Test("the off-screen host window translates with no other window involved (REQ-TR-30)")
        func hostWindowTranslates() async throws {
            try await requireTranslationPack(from: "es", to: "en")
            let (model, host) = hostTranslationBridge()
            defer { host.close() }
            let service = AppleTranslationService(model: model)
            let output = try await service.translate(text: "Gracias a todos por venir.",
                                                     from: Locale.Language(identifier: "es"),
                                                     to: Locale.Language(identifier: "en"))
            #expect(output.lowercased().contains("thank"), "“\(output)”")
        }

        @Test("warm session latency is recorded and stays under the regression ceiling (NFR-TR-01)")
        func keptSessionLatency() async throws {
            try await requireTranslationPack(from: "es", to: "en")
            let (model, host) = hostTranslationBridge()
            defer { host.close() }
            let service = AppleTranslationService(model: model)
            let src = Locale.Language(identifier: "es"), dst = Locale.Language(identifier: "en")
            await service.warmUp(from: src, to: dst)
            _ = try await service.translate(text: "Hola.", from: src, to: dst)   // first call loads the model

            var samples: [Double] = []
            for sentence in latencySentences {
                let start = ContinuousClock.now
                _ = try await service.translate(text: sentence, from: src, to: dst)
                samples.append(start.duration(to: .now).milliseconds)
            }
            let typical = median(samples)
            await LatencyReport.shared.record(fixture: "es→en AppleTranslationService warm (median)", stage: .translate,
                                              ms: typical)
            await LatencyReport.shared.record(fixture: "es→en AppleTranslationService warm (p90)", stage: .translate,
                                              ms: percentile90(samples))
            #expect(typical <= 400, "warm median \(typical) ms")
        }

        @Test("the first sentence after warm-up is fast (NFR-TR-01; cold it costs ~0.8–1.1 s)")
        func firstSentenceAfterWarmUp() async throws {
            try await requireTranslationPack(from: "es", to: "uk")
            let (model, host) = hostTranslationBridge()
            defer { host.close() }
            let service = AppleTranslationService(model: model)
            let src = Locale.Language(identifier: "es"), dst = Locale.Language(identifier: "uk")
            await service.warmUp(from: src, to: dst)
            try await Task.sleep(for: .seconds(1))   // the user's first words: real time, integration tier only

            let start = ContinuousClock.now
            _ = try await service.translate(text: latencySentences[1], from: src, to: dst)
            let first = start.duration(to: .now).milliseconds
            await LatencyReport.shared.record(fixture: "es→uk first sentence after warm-up", stage: .translate, ms: first)
            #expect(first <= 600, "first sentence \(first) ms")
        }
    }
}
