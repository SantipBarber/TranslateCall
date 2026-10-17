import Foundation
import Testing
@testable import TranslateCall

/// One test per run line × profile (M9 REQ-BH-23). Each plays the manifest's clips of its variant
/// through a traced session and writes `<out>/<profile>/<line>/raw.json`.
extension BenchTests {
    @Suite("Bench run lines") @MainActor
    struct BenchRunLineTests {
        /// Enabled when the profile is selected. A broken environment keeps the test enabled so it fails
        /// with the reason instead of passing by skipping.
        nonisolated static func selects(_ profile: BenchProfile) -> Bool {
            guard let env = try? BenchEnvironment.current() else { return true }
            return env.profiles.contains(profile)
        }

        private func run(_ line: BenchRunLine, _ profile: BenchProfile) async throws {
            let env = try BenchEnvironment.current()
            let manifest = try JSONDecoder().decode(BenchManifest.self, from: Data(contentsOf: env.manifest))
            let clips = manifest.clips(variant: line.variant, set: env.set)
            try requirePrerequisite(!clips.isEmpty,
                                    "clips for \(line.variant) in set \(env.set) — run `just bench-fetch`")
            try await requireSpeechAuthorization()
            try await requireTranslationPack(from: "es", to: "en")
            try await requireTranslationPack(from: "en", to: "es")
            let url = try #require(try await BenchRunner.run(line, profile: profile, env: env))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        @Test(.enabled(if: BenchRunLineTests.selects(.basic)))
        func outgoing_esES_en_basic() async throws { try await run(.outgoingEsESToEn, .basic) }

        @Test(.enabled(if: BenchRunLineTests.selects(.best)))
        func outgoing_esES_en_best() async throws { try await run(.outgoingEsESToEn, .best) }

        @Test(.enabled(if: BenchRunLineTests.selects(.basic)))
        func outgoing_es419_en_basic() async throws { try await run(.outgoingEs419ToEn, .basic) }

        @Test(.enabled(if: BenchRunLineTests.selects(.best)))
        func outgoing_es419_en_best() async throws { try await run(.outgoingEs419ToEn, .best) }

        @Test(.enabled(if: BenchRunLineTests.selects(.basic)))
        func outgoing_en_es_basic() async throws { try await run(.outgoingEnToEs, .basic) }

        @Test(.enabled(if: BenchRunLineTests.selects(.best)))
        func outgoing_en_es_best() async throws { try await run(.outgoingEnToEs, .best) }

        @Test(.enabled(if: BenchRunLineTests.selects(.basic)))
        func incoming_en_es_basic() async throws { try await run(.incomingEnToEs, .basic) }
    }
}
