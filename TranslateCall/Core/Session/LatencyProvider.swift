import Foundation

/// End of speech → first audio, per direction, for the panel's latency label (REQ-UI-46, D-3).
protocol LatencyProvider: AnyObject, Sendable {
    /// Latest latency for `direction`, or nil when unknown.
    func latestLatency(for direction: TranscriptDirection) -> Duration?
    /// false → the label and the "Show latency in the panel" setting are hidden.
    var canProvide: Bool { get }
}

/// Production until the latency thread's trace sink is on `main` (design §4.4).
final class NoLatencyProvider: LatencyProvider {
    nonisolated func latestLatency(for direction: TranscriptDirection) -> Duration? { nil }
    nonisolated var canProvide: Bool { false }
}

extension Duration {
    /// "0.9 s" for the panel.
    nonisolated var latencyLabel: String {
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.1f s", seconds)
    }
}
