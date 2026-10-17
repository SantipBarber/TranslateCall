import Foundation
import Testing
@testable import TranslateCall

/// Keeps the bench path alive in `just pr` (M9 design §8): Basic profile, one outgoing line.
extension IntegrationTests {
    @Suite("Bench smoke") @MainActor
    struct BenchSmokeTests {
        private static let stages: [TraceStage] = [
            .speechStart, .vadEnd, .sttFinal, .translated, .ttsFirstBuffer, .ttsEnd
        ]

        private func requireBasicPrerequisites() async throws {
            try await requireSpeechAuthorization()
            try await requireTranslationPack(from: "es", to: "en")
            try await requireTranslationPack(from: "en", to: "es")
        }

        private func speech(_ id: String) throws -> [Float] {
            let fixture = try #require(try Fixtures.all().first { $0.id == id })
            return try FileAudioSource.decode16kMono(Fixtures.url(for: fixture))
        }

        @Test func tracedSessionProducesCompleteTraces() async throws {
            try await requireBasicPrerequisites()
            let options = BenchOptions()
            let session = try await BenchPipelineFactory.make(.outgoingEsESToEn, options: options)
            try await BenchPipelineFactory.start(session, options: options)
            await session.player.playSilence(seconds: 2)   // translation warm-up (REQ-TR-05)
            for id in ["es-greeting", "es-meeting"] {
                _ = await session.player.play(try speech(id))
                await session.player.playSilence(seconds: 1.5)
            }
            let drained = await waitUntil(timeout: .seconds(20)) { session.tracer.openSeqs.isEmpty }
            let events = session.sink.events
            await session.tearDown()

            #expect(drained, "utterances still open after 20 s: \(events.map { "\($0.seq):\($0.stage)" })")
            let seqs = Set(events.filter { $0.stage == .vadEnd }.map(\.seq)).sorted()
            #expect(seqs.count >= 2, "expected at least 2 utterances, got \(seqs.count)")
            for seq in seqs {
                #expect(events.filter { $0.seq == seq }.map(\.stage) == Self.stages, "seq \(seq)")
            }
        }

        @Test func userDefaultsUntouched() async throws {
            try await requireBasicPrerequisites()
            func snapshot() -> NSDictionary {
                let all = UserDefaults.standard.dictionaryRepresentation()
                return all.filter { $0.key.hasPrefix("tlk.") || $0.key.hasPrefix("conversation.") } as NSDictionary
            }
            let before = snapshot()
            let options = BenchOptions()
            let session = try await BenchPipelineFactory.make(.outgoingEsESToEn, options: options)
            try await BenchPipelineFactory.start(session, options: options)
            await session.tearDown()
            #expect(snapshot().isEqual(before), "bench touched the real UserDefaults (NFR-BH-03)")
        }

        @Test func startRefusesEnergyVAD() async throws {
            try await requireBasicPrerequisites()
            let options = BenchOptions()
            let provider = VADProvider(loadSilero: { _ in throw BenchSetupError(description: "no silero") })
            let session = try await BenchPipelineFactory.make(
                .outgoingEsESToEn, options: options, vadProvider: provider)
            var refused: MissingPrerequisite?
            await withKnownIssue {
                do {
                    try await BenchPipelineFactory.start(session, options: options)
                } catch {
                    refused = error as? MissingPrerequisite
                }
            } matching: { issue in
                "\(issue)".contains("Silero VAD")
            }
            await session.tearDown()
            #expect(refused?.description.contains("Silero VAD") == true)
        }
    }
}
