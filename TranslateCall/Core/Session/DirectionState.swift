import Foundation

// MARK: - DirectionState

/// What one direction's chip shows in the status panel and the popover (REQ-UI-43, design §4.3).
/// Exactly one state, in this priority order.
nonisolated enum DirectionState: Equatable, Sendable {
    /// Incoming only: capture stopped ("Can't hear <App>").
    case unavailable(IncomingStopReason)
    case paused
    /// Outgoing only, speakers mode: the echo gate mutes the mic.
    case micPaused
    case speaking
    case translating
    /// The VAD hears speech ("Hearing you" / "Hearing them").
    case hearing
    case listening

    static func outgoing(paused: Bool, micPaused: Bool, speaking: Bool,
                         translating: Bool, speech: Bool) -> DirectionState {
        if paused { return .paused }
        if micPaused { return .micPaused }
        return common(speaking: speaking, translating: translating, speech: speech)
    }

    /// `.disabled` (no call app) is presented by the view from `IncomingStatus` directly.
    static func incoming(status: IncomingStatus, paused: Bool, speaking: Bool,
                         translating: Bool, speech: Bool) -> DirectionState {
        if case .stopped(let reason) = status { return .unavailable(reason) }
        if paused { return .paused }
        return common(speaking: speaking, translating: translating, speech: speech)
    }

    private static func common(speaking: Bool, translating: Bool, speech: Bool) -> DirectionState {
        if speaking { return .speaking }
        if translating { return .translating }
        if speech { return .hearing }
        return .listening
    }
}

// MARK: - Session phase

/// Drives the primary button, the panel and the menu bar dot. `launching`: "Open <App> and start"
/// is waiting for the call app to run (REQ-UI-34), before the coordinator starts (P24).
nonisolated enum SessionPhase: Sendable, Equatable {
    case idle, launching, starting, running
}

// MARK: - Panel title

/// The status panel and popover header (REQ-UI-42).
nonisolated enum PanelTitle: Equatable, Sendable {
    case starting, paused, partlyWorking, translating

    static func derive(isStarting: Bool, isPaused: Bool, incoming: DirectionState) -> PanelTitle {
        if isStarting { return .starting }
        if case .unavailable = incoming { return .partlyWorking }
        if isPaused { return .paused }
        return .translating
    }

    var text: String {
        switch self {
        case .starting: String(localized: "Starting…")
        case .paused: String(localized: "Paused")
        case .partlyWorking: String(localized: "Partly working")
        case .translating: String(localized: "Translating")
        }
    }
}
