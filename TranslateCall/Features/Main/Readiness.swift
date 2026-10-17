import Foundation

// MARK: - PairReadiness

/// The language pair, checked per direction like `AudioCoordinator.start` (REQ-UI-33).
nonisolated enum PairReadiness: Sendable, Equatable {
    case checking
    case ready
    /// A pack is missing; the display name of the language to download.
    case missing(language: String)
    case unsupported

    /// `outgoingInstalled` = source → target; a missing outgoing pack names the target language,
    /// a missing incoming one the source language (the target when both are missing).
    static func derive(outgoingInstalled: Bool, incomingInstalled: Bool, unsupported: Bool,
                       sourceName: String, targetName: String) -> PairReadiness {
        if unsupported { return .unsupported }
        if !outgoingInstalled { return .missing(language: targetName) }
        if !incomingInstalled { return .missing(language: sourceName) }
        return .ready
    }
}

// MARK: - Readiness

/// The setup window's primary button and pre-call cards (REQ-UI-08, 30…33, design §5.4).
nonisolated struct Readiness: Sendable, Equatable {
    enum Primary: Sendable, Equatable {
        case start
        case openAppAndStart(String)
        case download(String)
        case unsupportedPair
        case checking
        /// "Open <App> and start" is waiting for the app to run (REQ-UI-34, P24).
        case opening(String)
        case starting
        case stop
    }

    /// In display order: permission cards at the top, the rest under the call-app list.
    enum Card: Sendable, Equatable {
        case microphoneOff
        case screenRecordingOff
        case audioDriverMissing
        case callAppNotOpen(String)
    }

    var primary: Primary
    var primaryEnabled: Bool
    var cards: [Card]

    static func derive(permissions: PermissionState, blackHolePresent: Bool, pair: PairReadiness,
                       app: CallAppRow?, phase: SessionPhase) -> Readiness {
        switch phase {
        case .running: return Readiness(primary: .stop, primaryEnabled: true, cards: [])
        case .starting: return Readiness(primary: .starting, primaryEnabled: false, cards: [])
        case .launching: return Readiness(primary: .opening(app?.appName ?? ""), primaryEnabled: false, cards: [])
        case .idle: break
        }
        let cards = cards(permissions: permissions, blackHolePresent: blackHolePresent, app: app)
        let micOK = permissions.microphone != .denied
        switch pair {
        case .missing(let language): return Readiness(primary: .download(language), primaryEnabled: false, cards: cards)
        case .unsupported: return Readiness(primary: .unsupportedPair, primaryEnabled: false, cards: cards)
        case .checking: return Readiness(primary: .checking, primaryEnabled: false, cards: cards)
        case .ready: break
        }
        if let app, !app.isRunning, app.appURL != nil {
            return Readiness(primary: .openAppAndStart(app.appName), primaryEnabled: micOK, cards: cards)
        }
        return Readiness(primary: .start, primaryEnabled: micOK, cards: cards)
    }
}

nonisolated extension Readiness {
    static func cards(permissions: PermissionState, blackHolePresent: Bool, app: CallAppRow?) -> [Card] {
        var cards: [Card] = []
        if permissions.microphone == .denied { cards.append(.microphoneOff) }
        // Only incoming needs screen recording: no card when no call app is chosen.
        if app != nil, permissions.screenRecording == .denied { cards.append(.screenRecordingOff) }
        if !blackHolePresent { cards.append(.audioDriverMissing) }
        if let app, !app.isRunning, app.appURL != nil { cards.append(.callAppNotOpen(app.appName)) }
        return cards
    }
}

nonisolated extension Readiness.Primary {
    /// The button's title (REQ-UI-08).
    var title: String {
        switch self {
        case .start: String(localized: "Start translating")
        case .openAppAndStart(let app): String(localized: "Open \(app) and start")
        case .download(let language): String(localized: "Download \(language) to start")
        case .unsupportedPair: String(localized: "This pair isn't available")
        case .checking: String(localized: "Checking languages…")
        case .opening(let app): String(localized: "Opening \(app)…")
        case .starting: String(localized: "Starting…")
        case .stop: String(localized: "Stop translating")
        }
    }
}

// MARK: - Card copy

/// Each card's title and body (REQ-UI-31/32/32a), shared by the setup window and the popover.
nonisolated extension Readiness.Card {
    var title: String {
        switch self {
        case .microphoneOff: String(localized: "Your microphone is off for TranslateCall")
        case .screenRecordingOff: String(localized: "They can't be heard")
        case .audioDriverMissing: String(localized: "Audio driver missing")
        case .callAppNotOpen(let app): String(localized: "\(app) isn't open")
        }
    }

    var message: String {
        switch self {
        case .microphoneOff:
            String(localized: "Turn it on in System Settings so TranslateCall can translate your voice.")
        case .screenRecordingOff:
            String(localized: """
            Screen & System Audio Recording is off for TranslateCall, so it can't hear the other person in your call.
            """)
        case .audioDriverMissing:
            String(localized: "TranslateCall needs BlackHole 2ch to send your translated voice into the call.")
        case .callAppNotOpen(let app):
            String(localized: """
            TranslateCall will open it for you when you start. Then join or start your meeting in \(app).
            """)
        }
    }

    /// Only a denied microphone stops Start; the other cards inform (REQ-UI-32a, 33).
    var isBlocking: Bool { self == .microphoneOff }
}

nonisolated extension Readiness {
    /// The popover's idle state line (REQ-UI-60): nil = "Ready"; otherwise the first reason Start
    /// is blocked. Non-blocking cards never replace "Ready".
    var blockingReason: String? {
        guard !primaryEnabled else { return nil }
        return cards.first(where: \.isBlocking)?.title ?? primary.title
    }
}
