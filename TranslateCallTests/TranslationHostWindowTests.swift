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
        #expect(window.contentView != nil)
    }
}
