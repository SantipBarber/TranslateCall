import AppKit
import Testing
@testable import TranslateCall

@Suite("TranslationHostWindow (F8.5.4)") @MainActor
struct TranslationHostWindowTests {

    @Test("off screen, never key or main, hidden from the Window menu, kept when closed (REQ-TR-30)")
    func invisibleAndInert() {
        let host = TranslationHostWindow(outgoing: TranslationBridgeModel(), incoming: TranslationBridgeModel())
        defer { host.close() }
        let window = host.window
        #expect(window.frame.maxX < 0 && window.frame.maxY < 0)
        #expect(!window.canBecomeKey)
        #expect(!window.canBecomeMain)
        #expect(window.isExcludedFromWindowsMenu)
        #expect(window.ignoresMouseEvents)
        #expect(!window.isReleasedWhenClosed)
        #expect(!window.canHide)   // Cmd-H keeps it on screen
        #expect(!window.isRestorable)
        #expect(window.contentView != nil)
    }

    @Test("the host never qualifies for the menu bar's show-main-window lookup")
    func hostIsNotMainCandidate() {
        let host = TranslationHostWindow(outgoing: TranslationBridgeModel(), incoming: TranslationBridgeModel())
        defer { host.close() }
        #expect(host.window.isVisible)
        #expect(!(host.window.canBecomeMain && host.window.isVisible))
    }
}
