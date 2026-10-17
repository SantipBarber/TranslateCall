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

/// Whether the menu bar's Start must bring up the main window first (REQ-UI-36): something has to be
/// shown (a missing pack, a card, the Edge TTS consent). A failure nobody can predict is covered by
/// `CallSessionModel`, which brings the window up for an alert that stays (P27).
nonisolated enum MenuBarStartPolicy {
    static func needsMainWindow(readiness: Readiness, needsEdgeConsent: Bool) -> Bool {
        !readiness.primaryEnabled || !readiness.cards.isEmpty || needsEdgeConsent
    }
}
