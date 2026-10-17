import Foundation

/// The status item's dot (REQ-UI-61): green while translating, orange while paused or partly
/// working; no dot when idle or while the session is still launching or starting (P29).
nonisolated enum MenuBarDot: Equatable, Sendable {
    case none, green, orange

    static func derive(phase: SessionPhase, title: PanelTitle) -> MenuBarDot {
        switch phase {
        case .idle, .launching, .starting: return .none
        case .running: return title == .translating ? .green : .orange
        }
    }

    /// The base glyph; the dot is drawn over it.
    static let symbolName = "translate"
}
