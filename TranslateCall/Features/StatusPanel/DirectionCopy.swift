import Foundation

/// Texts of a direction row and chip (REQ-UI-42/43); `appName` is the call app's name.
nonisolated enum DirectionCopy {
    static func chip(_ state: DirectionState, direction: TranscriptDirection, appName: String) -> String {
        switch state {
        case .unavailable: String(localized: "Can't hear \(appName)")
        case .paused: String(localized: "Paused")
        case .micPaused: String(localized: "Mic paused")
        case .speaking: String(localized: "Speaking")
        case .translating: String(localized: "Translating…")
        case .hearing where direction == .outgoing: String(localized: "Hearing you")
        case .hearing: String(localized: "Hearing them")
        case .listening: String(localized: "Listening")
        }
    }

    /// The line under an unavailable "Them" row (replaces the old incoming banner text).
    static func unavailableLine(_ reason: IncomingStopReason, appName: String) -> String {
        switch reason {
        case .targetNotFound: String(localized: "\(appName) isn't running. Open it, then Retry.")
        case .permissionDenied: String(localized: "Screen & System Audio Recording is off for TranslateCall.")
        case .streamError(let detail): String(localized: "Call audio stopped: \(detail)")
        }
    }

    /// "Only your voice is translated" when no call app is chosen (`IncomingStatus.disabled`).
    static let outgoingOnlyLine = String(localized: "Only your voice is translated")

    /// The line under the "Them" row for `status` (replaces `IncomingStatusBanner.text`); nil while
    /// incoming is idle or active.
    static func incomingLine(_ status: IncomingStatus, appName: String) -> String? {
        switch status {
        case .idle, .active: nil
        case .disabled: outgoingOnlyLine
        case .starting: String(localized: "Connecting to \(appName)…")
        case .stopped(let reason): unavailableLine(reason, appName: appName)
        }
    }

    /// "Retry" is offered only for a stopped capture (replaces `IncomingStatusBanner.showsRetry`).
    static func showsRetry(_ status: IncomingStatus) -> Bool {
        if case .stopped = status { return true }
        return false
    }

    /// VoiceOver: "You, Spanish to German, speaking" (NFR-UI-04).
    static func accessibilityLabel(direction: TranscriptDirection, from source: String, to target: String,
                                   state: String) -> String {
        let who = direction == .outgoing ? String(localized: "You") : String(localized: "Them")
        return String(localized: "\(who), \(source) to \(target), \(state.lowercased())")
    }
}
