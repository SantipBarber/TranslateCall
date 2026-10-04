import Foundation

/// What the incoming pipeline captures (F8.5.1 REQ-C-20). A value type so the coordinator
/// and its tests never need an `SCRunningApplication`.
nonisolated enum CaptureTarget: Sendable, Equatable {
    case app(bundleID: String)
}

/// Why incoming capture is not running (REQ-C-31).
nonisolated enum IncomingStopReason: Sendable, Equatable {
    case targetNotFound(bundleID: String)
    case permissionDenied
    case streamError(String)

    init(error: Error) {
        switch error {
        case SystemAudioCaptureError.targetNotFound(let bundleID):
            self = .targetNotFound(bundleID: bundleID)
        case SystemAudioCaptureError.permissionDenied:
            self = .permissionDenied
        case SystemAudioCaptureError.streamFailed(let underlying):
            // The underlying text only: `message` already says "Call audio capture failed: …".
            self = .streamError(underlying.localizedDescription)
        default:
            self = .streamError(error.localizedDescription)
        }
    }

    var message: String {
        switch self {
        case .targetNotFound(let bundleID):
            return "The call app (\(bundleID)) is not running."
        case .permissionDenied:
            return "Screen Recording permission is required to hear the call."
        case .streamError(let detail):
            return "Call audio capture failed: \(detail)"
        }
    }
}

/// Incoming pipeline status published by `AudioCoordinator` (REQ-C-30).
nonisolated enum IncomingStatus: Sendable, Equatable {
    case idle
    case disabled
    case starting
    case active
    case stopped(IncomingStopReason)
}

/// Out-of-band events from `SystemAudioCapture` (REQ-C-32).
nonisolated enum SystemCaptureEvent: Sendable, Equatable {
    case stopped(IncomingStopReason)
}
