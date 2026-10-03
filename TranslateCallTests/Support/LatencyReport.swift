import Foundation

enum LatencyStage: String, Codable, Sendable {
    case vad, stt, translate, total
    case ttsFirstAudio = "tts_first_audio"
}

/// Collects per-stage latency during the integration tier and writes build/reports/latency.json (REQ-W-24).
///
/// Integration suites run in an unspecified order, so there is no reliable "last test" to write the
/// file; when `autoWritePath` is set the report is rewritten after every `record` (a few rows, cheap).
actor LatencyReport {
    static let shared: LatencyReport = {
        let env = ProcessInfo.processInfo.environment
        return LatencyReport(autoWritePath: env["TC_LATENCY_REPORT"].map { URL(fileURLWithPath: $0) },
                             commit: env["TC_COMMIT"] ?? "unknown")
    }()

    private let autoWritePath: URL?
    private let commit: String
    private var rows: [String: [String: Double]] = [:]
    private var order: [String] = []

    init(autoWritePath: URL? = nil, commit: String = "unknown") {
        self.autoWritePath = autoWritePath
        self.commit = commit
    }

    func record(fixture: String, stage: LatencyStage, ms: Double) {
        if rows[fixture] == nil { order.append(fixture) }
        rows[fixture, default: [:]]["\(stage.rawValue)_ms"] = ms
        if let autoWritePath { try? write(to: autoWritePath, commit: commit) }
    }

    func write(to url: URL, commit: String) throws {
        let fixtures: [[String: Any]] = order.map { id in
            var row: [String: Any] = rows[id] ?? [:]
            row["id"] = id
            return row
        }
        let doc: [String: Any] = [
            "commit": commit,
            "date": ISO8601DateFormatter().string(from: .now),
            "machine": Host.current().localizedName ?? "unknown",
            "fixtures": fixtures,
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}
