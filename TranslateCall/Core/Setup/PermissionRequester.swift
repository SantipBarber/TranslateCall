import AppKit
import AVFoundation
import CoreGraphics
import Foundation

/// The Privacy panes of System Settings that step 1 links to.
nonisolated enum PrivacyPane: Sendable, Equatable {
    case microphone
    case screenRecording

    var url: URL {
        switch self {
        case .microphone: PermissionState.microphoneSettingsURL
        case .screenRecording: PermissionState.screenRecordingSettingsURL
        }
    }
}

/// What step 1's "Allow…" buttons do (REQ-FR-11, 12); a protocol so the view logic runs with a fake.
@MainActor
protocol PermissionRequesting {
    /// Asks for microphone access (shows the system prompt when undecided); true when granted.
    func requestMicrophone() async -> Bool
    /// Triggers the system's screen recording prompt; the grant only shows after a relaunch.
    func requestScreenRecording()
    func openPrivacyPane(_ pane: PrivacyPane)
    /// Starts a second instance of this app and quits this one ("Reopen TranslateCall").
    func relaunch()
}

@MainActor
struct PermissionRequester: PermissionRequesting {
    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    func openPrivacyPane(_ pane: PrivacyPane) {
        NSWorkspace.shared.open(pane.url)
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
