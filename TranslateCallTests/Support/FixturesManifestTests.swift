import Foundation
import Testing

@Suite("Fixtures manifest")
struct FixturesManifestTests {
    @Test func everyEntryHasWavAndCoversThreeLanguages() throws {
        let all = try Fixtures.all()
        #expect(Set(all.map { String($0.lang.prefix(2)) }) == ["es", "en", "uk"])
        for fixture in all {
            #expect(FileManager.default.fileExists(atPath: Fixtures.url(for: fixture).path),
                    "missing \(fixture.id).wav — run just fixtures")
        }
    }

    @Test func langFilterSelectsByPrefix() throws {
        #expect(try Fixtures.lang("uk").map(\.id) == ["uk-greeting", "uk-thanks"])
    }
}
