import Foundation
import Testing
@testable import TranslateCall

private func row(running: Bool, installed: Bool = true) -> CallAppRow {
    CallAppRow(bundleID: "us.zoom.xos", title: "Zoom", appName: "Zoom", callAppID: "zoom", symbol: "video.fill",
               appURL: installed ? URL(fileURLWithPath: "/Applications/zoom.us.app") : nil, openURL: nil,
               isRunning: running)
}

private func derive(_ permissions: PermissionState = .allGranted, blackHole: Bool = true,
                    pair: PairReadiness = .ready, app: CallAppRow? = row(running: true),
                    phase: SessionPhase = .idle, downloading: Bool = false) -> Readiness {
    Readiness.derive(permissions: permissions, blackHolePresent: blackHole, pair: pair, app: app, phase: phase,
                     modelDownloading: downloading)
}

@Suite("Readiness (M9 UI core REQ-UI-33)")
struct ReadinessTests {

    @Test("everything ready → Start, no cards")
    func ready() {
        #expect(derive() == Readiness(primary: .start, primaryEnabled: true, cards: []))
        #expect(Readiness.Primary.start.title == "Start translating")
    }

    @Test("a model download in flight → Start waits for it (M9 UI settings S-7)")
    func modelDownloading() {
        let result = derive(app: row(running: false), downloading: true)
        #expect(result.primary == .waitingForDownload && !result.primaryEnabled)
        #expect(result.cards == [.callAppNotOpen("Zoom")])
        #expect(result.blockingReason == "Wait for the model download to finish")
        #expect(derive(pair: .missing(language: "Deutsch"), downloading: true).primary == .download("Deutsch"))
        #expect(derive(phase: .running, downloading: true).primary == .stop)
    }

    @Test("microphone denied → card at the top and Start disabled (REQ-UI-32/33)")
    func micDenied() {
        let result = derive(PermissionState(microphone: .denied, screenRecording: .granted))
        #expect(result.cards == [.microphoneOff])
        #expect(!result.primaryEnabled)
    }

    @Test("microphone not asked yet does not block: the system asks at Start")
    func micNotDetermined() {
        #expect(derive(PermissionState(microphone: .notDetermined, screenRecording: .granted)).primaryEnabled)
    }

    @Test("screen recording denied → card only, Start still works; no card when no call app is chosen")
    func screenDenied() {
        let denied = PermissionState(microphone: .granted, screenRecording: .denied)
        let result = derive(denied)
        #expect(result.cards == [.screenRecordingOff])
        #expect(result.primaryEnabled)
        #expect(derive(denied, app: nil).cards.isEmpty)
    }

    @Test("BlackHole missing → audio driver card, Start not blocked (REQ-UI-32a)")
    func blackHoleMissing() {
        let result = derive(blackHole: false)
        #expect(result.cards == [.audioDriverMissing])
        #expect(result.primary == .start && result.primaryEnabled)
    }

    @Test("a pack missing → Download <language> to start, disabled (REQ-UI-30)")
    func packMissing() {
        let result = derive(pair: .missing(language: "Deutsch"))
        #expect(result.primary == .download("Deutsch"))
        #expect(!result.primaryEnabled)
        #expect(result.primary.title == "Download Deutsch to start")
    }

    @Test("app installed but not running → card + Open <App> and start (REQ-UI-31)")
    func appNotOpen() {
        let result = derive(app: row(running: false))
        #expect(result.cards == [.callAppNotOpen("Zoom")])
        #expect(result.primary == .openAppAndStart("Zoom") && result.primaryEnabled)
        #expect(result.primary.title == "Open Zoom and start")
    }

    @Test("a chosen app that is no longer installed → plain Start (incoming will show Can't hear)")
    func appUninstalled() {
        #expect(derive(app: row(running: false, installed: false)).primary == .start)
    }

    @Test("session running → Stop; starting → disabled; launching → Opening <App>…, disabled (REQ-UI-34)")
    func phases() {
        #expect(derive(phase: .running) == Readiness(primary: .stop, primaryEnabled: true, cards: []))
        #expect(derive(phase: .starting).primaryEnabled == false)
        let launching = derive(app: row(running: false), phase: .launching)
        #expect(launching == Readiness(primary: .opening("Zoom"), primaryEnabled: false, cards: []))
        #expect(launching.primary.title == "Opening Zoom…")
    }

    @Test("the popover's line: Ready, or the first blocking reason; informative cards never replace Ready")
    func blockingReason() {
        #expect(derive().blockingReason == nil)
        #expect(derive(blackHole: false).blockingReason == nil, "audio driver card does not block")
        #expect(derive(app: row(running: false)).blockingReason == nil, "Open Zoom and start is enabled")
        let micOff = derive(PermissionState(microphone: .denied, screenRecording: .denied))
        #expect(micOff.blockingReason == "Your microphone is off for TranslateCall")
        #expect(derive(pair: .missing(language: "Deutsch")).blockingReason == "Download Deutsch to start")
        #expect(Readiness.Card.callAppNotOpen("Zoom").title == "Zoom isn't open")
    }

    @Test("pair per direction: outgoing missing names the target, incoming the source; unsupported wins")
    func pairReadiness() {
        let both = PairReadiness.derive(outgoingInstalled: false, incomingInstalled: false, unsupported: false,
                                        sourceName: "Español", targetName: "Deutsch")
        let reverse = PairReadiness.derive(outgoingInstalled: true, incomingInstalled: false, unsupported: false,
                                           sourceName: "Español", targetName: "Deutsch")
        #expect(both == .missing(language: "Deutsch"))
        #expect(reverse == .missing(language: "Español"))
        #expect(PairReadiness.derive(outgoingInstalled: false, incomingInstalled: false, unsupported: true,
                                     sourceName: "", targetName: "") == .unsupported)
    }
}
