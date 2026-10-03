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
    /// In the integration tier, writes `<repo>/build/reports/latency.json` (override with `TC_LATENCY_REPORT`).
    /// xcodebuild does not forward shell env vars to the test host, so the default is derived from the source path.
    static let shared: LatencyReport = {
        let env = ProcessInfo.processInfo.environment
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let defaultPath = TestTier.current == .integration
            ? repoRoot.appendingPathComponent("build/reports/latency.json") : nil
        return LatencyReport(autoWritePath: env["TC_LATENCY_REPORT"].map { URL(fileURLWithPath: $0) } ?? defaultPath,
                             commit: env["TC_COMMIT"] ?? gitShortHead(in: repoRoot))
    }()

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    private static func gitShortHead(in repo: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path, "rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "unknown" }
        process.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
            "machine": Self.hardwareModel(), // model id, not the user-chosen computer name
            "fixtures": fixtures,
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}
