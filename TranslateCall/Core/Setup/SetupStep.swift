import Foundation

/// The assistant's four steps, in sidebar order (REQ-FR-01).
nonisolated enum SetupStep: Int, CaseIterable, Sendable {
    case permissions
    case audioDriver
    case callAppMic
    case test

    var title: String {
        switch self {
        case .permissions: String(localized: "Permissions")
        case .audioDriver: String(localized: "Audio driver")
        case .callAppMic: String(localized: "Call app microphone")
        case .test: String(localized: "Test")
        }
    }

    /// The step's state from the live setup inputs (REQ-FR-01): done, needs attention, or not done.
    /// `callAppMicDone` (confirmed, or "None" chosen) and `testResult` (step 4's checks) are computed
    /// elsewhere, so they pass straight through.
    func status(permissions: PermissionState, blackHolePresent: Bool, hasOtherBlackHole: Bool,
                callAppMicDone: Bool, testResult: SetupStepStatus) -> SetupStepStatus {
        switch self {
        case .permissions:
            return permissions == .allGranted ? .done : .todo
        case .audioDriver:
            if blackHolePresent { return .done }
            return hasOtherBlackHole ? .attention : .todo
        case .callAppMic:
            return callAppMicDone ? .done : .todo
        case .test:
            return testResult
        }
    }
}

/// A sidebar step's state: not done, done, or needs attention (REQ-FR-01).
nonisolated enum SetupStepStatus: Sendable, Equatable {
    case todo
    case done
    case attention
}
