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
}
