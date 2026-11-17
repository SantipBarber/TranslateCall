import Testing
@testable import TranslateCall

@Suite("Menu bar start policy")
struct MenuBarStartTests {
    private let ready = Readiness(primary: .start, primaryEnabled: true, cards: [])

    @Test("start needs the main window only when something must be shown")
    func startNeedsWindowOnlyWhenSomethingMustBeShown() {
        #expect(!MenuBarStartPolicy.needsMainWindow(readiness: ready, needsEdgeConsent: false))
        let download = Readiness(primary: .download("Deutsch"), primaryEnabled: false, cards: [])
        #expect(MenuBarStartPolicy.needsMainWindow(readiness: download, needsEdgeConsent: false))
        let card = Readiness(primary: .start, primaryEnabled: true, cards: [.screenRecordingOff])
        #expect(MenuBarStartPolicy.needsMainWindow(readiness: card, needsEdgeConsent: false))
        #expect(MenuBarStartPolicy.needsMainWindow(readiness: ready, needsEdgeConsent: true))
    }

    @Test("Start/Stop is off while launching, starting or rehearsing")
    func startStopOffWhileBusy() {
        for phase in [SessionPhase.launching, .starting, .rehearsing] {
            #expect(MenuBarStartPolicy.isBusy(phase: phase))
            #expect(!MenuBarStartPolicy.canToggle(phase: phase, isStarting: false))
        }
        #expect(!MenuBarStartPolicy.isBusy(phase: .idle))
        #expect(!MenuBarStartPolicy.isBusy(phase: .running))
        #expect(MenuBarStartPolicy.canToggle(phase: .idle, isStarting: false))
        #expect(MenuBarStartPolicy.canToggle(phase: .running, isStarting: false))
        #expect(!MenuBarStartPolicy.canToggle(phase: .idle, isStarting: true))
    }
}
