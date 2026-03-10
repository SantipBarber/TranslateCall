import Foundation

/// Known video call applications with per-app setup instructions.
enum VideoCallApp: String, CaseIterable, Identifiable {
    case zoom    = "us.zoom.xos"
    case teams   = "com.microsoft.teams2"
    case meet    = "com.google.meet"     // browser-based — matched by displayName
    case discord = "com.discord"
    case generic = ""                    // fallback

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zoom:    return "Zoom"
        case .teams:   return "Microsoft Teams"
        case .meet:    return "Google Meet"
        case .discord: return "Discord"
        case .generic: return "Video Call App"
        }
    }

    var sfSymbol: String {
        switch self {
        case .zoom:    return "video.fill"
        case .teams:   return "person.3.fill"
        case .meet:    return "video.bubble.left.fill"
        case .discord: return "bubble.left.and.bubble.right.fill"
        case .generic: return "video"
        }
    }

    var settingsPath: String {
        switch self {
        case .zoom:    return "Settings → Audio → Microphone"
        case .teams:   return "Settings → Devices → Microphone"
        case .meet:    return "Meeting controls → Microphone settings"
        case .discord: return "Settings → Voice & Video → Input Device"
        case .generic: return "Settings → Audio / Microphone"
        }
    }

    var microphoneSteps: [String] {
        switch self {
        case .zoom:
            return [
                "Open Zoom and sign in.",
                "Click the gear icon to open Settings.",
                "Select the Audio tab.",
                "Under Microphone, open the dropdown and choose BlackHole 2ch.",
                "Close Settings — Zoom is now receiving TranslateCall audio."
            ]
        case .teams:
            return [
                "Open Microsoft Teams.",
                "Click your profile picture, then Settings.",
                "Select Devices in the sidebar.",
                "Under Microphone, choose BlackHole 2ch from the dropdown.",
                "Close Settings — Teams is now receiving TranslateCall audio."
            ]
        case .meet:
            return [
                "Open Google Meet in your browser and start or join a meeting.",
                "Click the three-dot menu at the bottom right.",
                "Select Settings.",
                "Under Audio, open the Microphone dropdown and choose BlackHole 2ch.",
                "Click Done — Meet is now receiving TranslateCall audio."
            ]
        case .discord:
            return [
                "Open Discord.",
                "Click the gear icon near your username to open User Settings.",
                "Select Voice & Video in the sidebar.",
                "Under Input Device, choose BlackHole 2ch from the dropdown.",
                "Close Settings — Discord is now receiving TranslateCall audio."
            ]
        case .generic:
            return [
                "Open your video call app.",
                "Navigate to the app's Audio or Sound settings.",
                "Locate the Microphone or Input Device selector.",
                "Choose BlackHole 2ch as the microphone.",
                "Your video call app will now receive TranslateCall's translated audio."
            ]
        }
    }

    var estimatedMinutes: Int { 2 }

    /// Returns the `VideoCallApp` matching the given bundle identifier or display name.
    /// - Tries exact `rawValue` match on `bundleID` first (non-empty).
    /// - Then tries case-insensitive `displayName`-contains match.
    /// - Falls back to `.generic`.
    static func matching(bundleID: String, displayName: String) -> VideoCallApp {
        // 1. Exact bundle ID match
        if !bundleID.isEmpty,
           let match = VideoCallApp(rawValue: bundleID), match != .generic {
            return match
        }
        // 2. Display-name contains match (for browser-based apps like Meet)
        let lower = displayName.lowercased()
        if lower.contains("zoom") { return .zoom }
        if lower.contains("teams") { return .teams }
        if lower.contains("meet") { return .meet }
        if lower.contains("discord") { return .discord }
        return .generic
    }
}
