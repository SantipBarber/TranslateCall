import Testing
@testable import TranslateCall

@Suite("SetupWindowOpener (REQ-FR-02)")
@MainActor
struct SetupWindowOpenerTests {
    @Test("openerCallsOpenWindow: open() calls the handed-over openWindow each time")
    func openerCallsOpenWindow() {
        let opener = SetupWindowOpener()
        var calls = 0
        opener.openWindow = { calls += 1 }
        opener.open()
        opener.open()
        #expect(calls == 2)
    }

    @Test("open() without a handler does nothing")
    func openWithoutHandler() {
        SetupWindowOpener().open()
    }

    @Test("the window id is setup")
    func windowID() {
        #expect(SetupWindowOpener.windowID == "setup")
    }
}
