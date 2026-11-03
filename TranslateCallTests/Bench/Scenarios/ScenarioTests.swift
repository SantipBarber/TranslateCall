import Foundation
import Testing
@testable import TranslateCall

/// One test per scenario selected by `TC_SCENARIO` (a name, or `all`). Run through `just scenario`.
extension BenchTests {
    @Suite("Scenarios") @MainActor
    struct ScenarioTests {
        nonisolated static var selected: [String] {
            switch ProcessInfo.processInfo.environment["TC_SCENARIO"] ?? "" {
            case "": []
            case "all": ScenarioCatalog.all.map(\.name)
            case let names: names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }

        @Test(.enabled(if: !ScenarioTests.selected.isEmpty, "set TC_SCENARIO — run `just scenario <name>`"),
              arguments: ScenarioTests.selected)
        func scenario(_ name: String) async throws {
            let scenario = try #require(ScenarioCatalog.named(name),
                                        "unknown scenario \(name) (known: \(ScenarioCatalog.all.map(\.name)))")
            let env = try BenchEnvironment.current()
            try await requireSpeechAuthorization()
            try await requireTranslationPack(from: "en", to: "es")
            try await requireTranslationPack(from: "es", to: "en")
            let result = try await ScenarioRunner.run(scenario, env: env)
            for verdict in result.verdicts {
                print("SCENARIO \(name) \(verdict.passed ? "PASS" : "FAIL") \(verdict.rule): \(verdict.summary)")
                #expect(verdict.passed, "\(name) \(verdict.rule): \(verdict.summary)")
            }
        }
    }
}
