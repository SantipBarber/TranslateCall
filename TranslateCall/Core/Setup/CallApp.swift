import Foundation

// MARK: - CallApp

/// A known call app for the setup window's list (REQ-UI-02…04, design §6).
nonisolated struct CallApp: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case native
        /// Runs in the default browser; "Open" opens this URL.
        case browser(URL)
    }

    let id: String
    let displayName: String
    /// All known bundle IDs, newest first.
    let bundleIDs: [String]
    /// Shown when the app icon cannot be read.
    let symbol: String
    let kind: Kind

    static let meetURL = URL(string: "https://meet.google.com")!

    /// In list order (the prototype's order, then the brief's extra apps).
    static let catalog: [CallApp] = [
        CallApp(id: "teams", displayName: "Microsoft Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
                symbol: "person.3.fill", kind: .native),
        CallApp(id: "zoom", displayName: "Zoom", bundleIDs: ["us.zoom.xos"], symbol: "video.fill", kind: .native),
        CallApp(id: "meet", displayName: "Google Meet", bundleIDs: [], symbol: "globe", kind: .browser(meetURL)),
        CallApp(id: "facetime", displayName: "FaceTime", bundleIDs: ["com.apple.FaceTime"],
                symbol: "video.circle.fill", kind: .native),
        CallApp(id: "webex", displayName: "Webex", bundleIDs: ["Cisco-Systems.Spark", "com.cisco.webexmeetingsapp"],
                symbol: "video.bubble.fill", kind: .native),
        CallApp(id: "slack", displayName: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"],
                symbol: "number", kind: .native),
        CallApp(id: "discord", displayName: "Discord", bundleIDs: ["com.hnc.Discord", "com.discord"],
                symbol: "bubble.left.and.bubble.right.fill", kind: .native)
    ]
}

// MARK: - CallAppRow

/// One row of the Call app list: an installed app and its live state.
nonisolated struct CallAppRow: Identifiable, Sendable, Equatable {
    /// The capture target's bundle ID (the browser's for Meet).
    var id: String { bundleID }
    let bundleID: String
    /// "Microsoft Teams", "Google Meet · Chrome".
    let title: String
    /// For copy such as "Open Zoom and start" ("Google Meet" for Meet).
    let appName: String
    /// The catalog entry; nil for an "Other app…" choice.
    let callAppID: String?
    let symbol: String
    /// The installed app (icon, launch); nil when it is no longer installed.
    let appURL: URL?
    /// Meet: the page to open instead of launching the app.
    let openURL: URL?
    var isRunning: Bool
}
