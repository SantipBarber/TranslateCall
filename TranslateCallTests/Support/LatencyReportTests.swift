import Foundation
import Testing
@testable import TranslateCall

@Suite("LatencyReport")
struct LatencyReportTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
    }

    @Test func writesFixturesGroupedById() async throws {
        let report = LatencyReport()
        await report.record(fixture: "es-a", stage: .stt, ms: 410)
        await report.record(fixture: "es-a", stage: .total, ms: 1400)
        await report.record(fixture: "en-b", stage: .vad, ms: 700)
        let url = tempURL()
        try await report.write(to: url, commit: "abc1234")

        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["commit"] as? String == "abc1234")
        let fixtures = try #require(json["fixtures"] as? [[String: Any]])
        let esA = try #require(fixtures.first { $0["id"] as? String == "es-a" })
        #expect(esA["stt_ms"] as? Double == 410)
        #expect(esA["total_ms"] as? Double == 1400)
        #expect(fixtures.map { $0["id"] as? String } == ["es-a", "en-b"]) // insertion order kept
    }

    @Test func autoWritesAfterEachRecord() async throws {
        let url = tempURL()
        let report = LatencyReport(autoWritePath: url, commit: "c0ffee")
        await report.record(fixture: "x", stage: .vad, ms: 1)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["commit"] as? String == "c0ffee")
    }
}
