import Testing
@testable import TranslateCall

@MainActor
private final class FakeWindow: MainWindowCandidate {
    let canBecomeMain: Bool
    private(set) var isVisible: Bool
    let isMiniaturized: Bool
    private(set) var raised = false

    init(canBecomeMain: Bool, isVisible: Bool, isMiniaturized: Bool = false) {
        self.canBecomeMain = canBecomeMain
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
    }

    func raise() { raised = true }

    /// What `NSApplication.unhide` does: orders the window back in.
    func orderBackIn() { isVisible = true }
}

@Suite("MainWindowOpener (F8.5.4)") @MainActor
struct MainWindowOpenerTests {

    private func makeOpener() -> (MainWindowOpener, opens: () -> Int) {
        let opener = MainWindowOpener()
        var count = 0
        opener.openWindow = { count += 1 }
        return (opener, { count })
    }

    @Test("only the invisible-to-main host is on screen: a new main window is requested")
    func hostOnlyOpensWindow() {
        let (opener, opens) = makeOpener()
        let host = FakeWindow(canBecomeMain: false, isVisible: true)
        #expect(opener.show(in: [host]) == .openRequested)
        #expect(opens() == 1)
        #expect(!host.raised)
    }

    @Test("a closed (invisible) main window does not count: a new one is requested")
    func closedMainOpensWindow() {
        let (opener, opens) = makeOpener()
        let closed = FakeWindow(canBecomeMain: true, isVisible: false)
        #expect(opener.show(in: [closed, FakeWindow(canBecomeMain: false, isVisible: true)]) == .openRequested)
        #expect(opens() == 1)
    }

    @Test("a visible main window is raised and nothing is opened")
    func visibleMainIsRaised() {
        let (opener, opens) = makeOpener()
        let host = FakeWindow(canBecomeMain: false, isVisible: true)
        let main = FakeWindow(canBecomeMain: true, isVisible: true)
        #expect(opener.show(in: [host, main]) == .raised)
        #expect(main.raised && !host.raised)
        #expect(opens() == 0)
    }

    @Test("a window minimised to the Dock is restored, not duplicated")
    func miniaturizedIsRaised() {
        let (opener, opens) = makeOpener()
        let main = FakeWindow(canBecomeMain: true, isVisible: false, isMiniaturized: true)
        #expect(opener.show(in: [main]) == .raised)
        #expect(main.raised && opens() == 0)
    }

    @Test("no windows at all: a new main window is requested")
    func noWindowsOpens() {
        let (opener, opens) = makeOpener()
        #expect(opener.show(in: []) == .openRequested)
        #expect(opens() == 1)
    }

    @Test("hidden app (Cmd-H): unhide first, then the existing main window is raised and nothing is opened")
    func hiddenAppUnhidesInsteadOfDuplicating() {
        let (opener, opens) = makeOpener()
        let main = FakeWindow(canBecomeMain: true, isVisible: false)
        var unhides = 0
        let outcome = opener.show(in: [main], appIsHidden: true, unhide: {
            unhides += 1
            main.orderBackIn()
        })
        #expect(outcome == .raised)
        #expect(unhides == 1)
        #expect(main.raised && opens() == 0)
    }

    @Test("a visible app is never unhidden")
    func visibleAppIsNotUnhidden() {
        let (opener, _) = makeOpener()
        var unhides = 0
        _ = opener.show(in: [FakeWindow(canBecomeMain: true, isVisible: true)], unhide: { unhides += 1 })
        #expect(unhides == 0)
    }
}
