import AVFoundation
import Foundation
import Testing

/// One entry of `Fixtures/Audio/manifest.json` (regenerate WAVs with `just fixtures`).
struct AudioFixture: Decodable, Sendable, CustomTestStringConvertible {
    let id: String
    let lang: String
    let voice: String
    let text: String
    let maxWer: Double

    var locale: Locale { Locale(identifier: lang) }
    var testDescription: String { id }
}

/// Locates fixtures in the source tree (not the bundle) so they need no resource wiring.
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Audio")

    static func all() throws -> [AudioFixture] {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode([AudioFixture].self, from: data)
    }

    static func lang(_ prefix: String) throws -> [AudioFixture] {
        try all().filter { $0.lang.hasPrefix(prefix) }
    }

    static func url(for fixture: AudioFixture) -> URL {
        directory.appendingPathComponent("\(fixture.id).wav")
    }
}

extension AudioFixture {
    /// Speech duration of the WAV (without the trailing silence FileAudioSource appends).
    var durationSeconds: Double {
        guard let file = try? AVAudioFile(forReading: Fixtures.url(for: self)) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
