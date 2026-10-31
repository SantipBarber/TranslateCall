import Foundation
import Testing
@testable import TranslateCall

/// Keeps the bench path alive in `just pr` (M9 design §8): Basic profile, one outgoing line.
extension IntegrationTests {
    @Suite("Bench smoke") @MainActor
    struct BenchSmokeTests {
        /// A delivered sentence, without `.committed`: a committed tentative stamps it once, anywhere after
        /// `.vadEnd` (the commit lands at the end of the pause, before or after STT); a final has none.
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
            let stagesBySeq = Dictionary(uniqueKeysWithValues: seqs.map { seq in
                (seq, events.filter { $0.seq == seq }.map(\.stage))
            })
            // Early processing (FR-QS.5): a tentative withdrawn when speech resumed ends as `.retracted`.
            let delivered = seqs.filter { stagesBySeq[$0]?.last != .retracted }
            #expect(delivered.count >= 2, "expected at least 2 delivered utterances, got \(delivered.count)")
            for seq in seqs {
                let stages = stagesBySeq[seq] ?? []
                if stages.last == .retracted {
                    #expect(Array(stages.prefix(2)) == [.speechStart, .vadEnd], "retracted seq \(seq): \(stages)")
                    continue
                }
                #expect(stages.filter { $0 == .committed }.count <= 1, "seq \(seq): \(stages)")
                #expect(stages.filter { $0 != .committed } == Self.stages, "seq \(seq): \(stages)")
                if let commit = stages.firstIndex(of: .committed) {
                    #expect(commit > 1, "seq \(seq): committed before vadEnd: \(stages)")
                }
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
            let provider = VADProvider(loadSilero: { _ in throw BenchSetupError(description: "no silero") },
                                       preferred: { .silero })
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

        @Test func bestUsesParakeetOnlyOnEnglishOutgoingLines() {
            let best = BenchOptions(profile: .best)
            let engines = [BenchRunLine.outgoingEsESToEn, .outgoingEs419ToEn, .outgoingEnToEs, .incomingEnToEs]
                .map { BenchPipelineFactory.sttEngine(for: $0, options: best) }
            #expect(engines == [.appleSpeech, .appleSpeech, .parakeet, .appleSpeech])
            #expect(BenchPipelineFactory.sttEngine(for: .outgoingEsESToEn, options: BenchOptions()) == .appleSpeech)
            var whisper = BenchOptions()
            whisper.overrideSTT = .whisper
            #expect(BenchPipelineFactory.sttEngine(for: .incomingEnToEs, options: whisper) == .whisper)
        }

        @Test(arguments: [
            ("Silero VAD", BenchRunLine.outgoingEsESToEn, BenchOptions()),
            ("Parakeet", BenchRunLine.outgoingEnToEs, BenchOptions(profile: .best)),
            ("Whisper", BenchRunLine.incomingEnToEs, BenchOptions(overrideSTT: .whisper)),
            ("Kokoro", BenchRunLine.outgoingEsESToEn, BenchOptions(overrideTTS: .kokoro))
        ])
        func absentModelRefusesWithoutLoading(model: String, line: BenchRunLine, options: BenchOptions) async {
            var options = options
            // Every model "present" except the one under test.
            let (present, absent): (@Sendable () async -> Bool, @Sendable () async -> Bool) = ({ true }, { false })
            options.presence = BenchModelPresence(
                silero: model == "Silero VAD" ? absent : present, parakeet: model == "Parakeet" ? absent : present,
                whisper: model == "Whisper" ? absent : present, kokoro: model == "Kokoro" ? absent : present,
                voiceClone: present)
            var refused: MissingPrerequisite?
            await withKnownIssue {
                do {
                    _ = try await BenchPipelineFactory.make(line, options: options)
                } catch {
                    refused = error as? MissingPrerequisite
                }
            } matching: { issue in
                "\(issue)".contains("\(model) model")
            }
            #expect(refused?.description.contains("download it in the app first (M5)") == true)
        }
    }
}
