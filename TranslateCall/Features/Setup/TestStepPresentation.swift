import Foundation

/// The strings step 4 shows for each check and for the rehearsal box (REQ-FR-40…43, 50…55).
nonisolated enum TestStepPresentation {
    static func micLine(_ state: CheckState) -> String {
        switch state {
        case .idle, .running: String(localized: "Say something")
        case .passed: String(localized: "We can hear you")
        case .failed(let failure): failure.message
        }
    }

    static func routeLine(_ state: CheckState) -> String {
        switch state {
        case .idle: String(localized: "Test")
        case .running: String(localized: "Testing…")
        case .passed: String(localized: "BlackHole receives audio")
        case .failed(let failure): failure.message
        }
    }

    static func incomingLine(appName: String) -> String {
        String(localized: "Audio from \(appName) — checked in your first call")
    }

    /// What the rehearsal box says, top to bottom; empty while it only offers to start.
    static func rehearsalLines(_ state: RehearsalState, appName: String, myLanguage: String) -> [String] {
        switch state {
        case .unavailable(let reason): [reason]
        case .ready, .needsConsent: []
        case .preparing: [String(localized: "Preparing…")]
        case .listening: [String(localized: "Say a short sentence in \(myLanguage)")]
        case .translating(let said): [String(localized: "You said: \(said)")]
        case .passed(let said, let received):
            [String(localized: "You said: \(said)"), String(localized: "\(appName) receives: \(received)")]
        case .failed(let failure): [failure.message]
        }
    }

    static let consentMessage = String(localized: """
        No voice is available for this language on your device. Enable Cloud TTS? \
        Text will be sent to Microsoft for speech synthesis.
        """)
}
