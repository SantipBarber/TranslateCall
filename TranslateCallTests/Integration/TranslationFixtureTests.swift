import AppKit
import NaturalLanguage
import Testing
@testable import TranslateCall

extension IntegrationTests {
    @Suite("Translation", .serialized) @MainActor
    struct TranslationFixtureTests {
        struct Pair: Sendable, CustomTestStringConvertible {
            let fixtureID: String
            let source: String
            let target: String
            let expected: NLLanguage
            var testDescription: String { "\(fixtureID) \(source)→\(target)" }
        }

        nonisolated static let pairs: [Pair] = [
            Pair(fixtureID: "es-greeting", source: "es", target: "en", expected: .english),
            Pair(fixtureID: "en-hear", source: "en", target: "es", expected: .spanish),
            Pair(fixtureID: "es-meeting", source: "es", target: "uk", expected: .ukrainian),
            Pair(fixtureID: "uk-greeting", source: "uk", target: "en", expected: .english),
        ]

        @Test("Apple Translation", arguments: pairs)
        func translate(_ pair: Pair) async throws {
            let fixture = try #require(try Fixtures.all().first { $0.id == pair.fixtureID })
            let src = Locale.Language(identifier: pair.source), dst = Locale.Language(identifier: pair.target)
            let (model, window) = hostTranslationBridge()
            defer { window.close() }
            let service = AppleTranslationService(model: model)
            try await requireTranslationPack(from: pair.source, to: pair.target)

            let start = ContinuousClock.now
            let output = try await service.translate(text: fixture.text, from: src, to: dst)
            await LatencyReport.shared.record(fixture: "\(pair.fixtureID)→\(pair.target)", stage: .translate,
                                              ms: start.duration(to: .now).milliseconds)
            #expect(!output.isEmpty)
            #expect(NLLanguageRecognizer.dominantLanguage(for: output) == pair.expected, "“\(output)”")
        }
    }
}
