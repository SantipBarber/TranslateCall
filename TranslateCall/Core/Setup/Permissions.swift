import AVFoundation
import CoreGraphics
import Foundation

nonisolated enum PermissionStatus: Sendable, Equatable {
    case granted, denied, notDetermined
}

/// Microphone and Screen & System Audio Recording, re-read when the app becomes active (REQ-UI-32).
nonisolated struct PermissionState: Sendable, Equatable {
    var microphone: PermissionStatus
    var screenRecording: PermissionStatus

    static let allGranted = PermissionState(microphone: .granted, screenRecording: .granted)

    /// The system's answer now. Screen recording cannot report "not asked yet": not granted = denied.
    static func current() -> PermissionState {
        let mic: PermissionStatus = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        return PermissionState(microphone: mic, screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .denied)
    }

    static let microphoneSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let screenRecordingSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}
