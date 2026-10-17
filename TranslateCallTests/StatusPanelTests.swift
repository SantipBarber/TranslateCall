import AppKit
import SwiftUI
import Testing
@testable import TranslateCall

@Suite("StatusPanel (M9 UI core REQ-UI-41)") @MainActor
struct StatusPanelTests {

    private func makeController() -> StatusPanelController {
        StatusPanelController(size: NSSize(width: 320, height: 174), autosaveName: nil,
                              screenFrame: { NSRect(x: 0, y: 0, width: 1440, height: 875) }) { _ in NSView() }
    }

    @Test("floating, non-activating, on every Space and over full screen; never key or main")
    func neverTakesFocus() {
        let panel = makeController().panel
        defer { panel.close() }
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.isFloatingPanel)
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.isMovableByWindowBackground)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.isExcludedFromWindowsMenu)
    }

    @Test("default position: top-right of the visible frame, inset 16 pt")
    func defaultPosition() {
        let controller = makeController()
        defer { controller.panel.close() }
        #expect(controller.panel.frame.origin == NSPoint(x: 1440 - 320 - 16, y: 875 - 174 - 16))
    }

    @Test("show does not make it key; hide orders it out")
    func showHide() {
        let controller = makeController()
        defer { controller.panel.close() }
        controller.show()
        #expect(controller.isVisible)
        #expect(!controller.panel.isKeyWindow)
        controller.hide()
        #expect(!controller.isVisible)
    }

    @Test("resizing keeps the top edge (compact → expanded grows down)")
    func resizeKeepsTop() {
        let controller = makeController()
        defer { controller.panel.close() }
        let top = controller.panel.frame.maxY
        controller.resize(to: NSSize(width: 340, height: 380))
        #expect(controller.panel.frame.maxY == top)
        #expect(controller.panel.frame.size == NSSize(width: 340, height: 380))
    }

    @Test("the panel never qualifies as the main window for the menu bar's lookup")
    func notAMainCandidate() {
        let controller = makeController()
        defer { controller.panel.close() }
        controller.show()
        #expect(MainWindowOpener().show(in: [controller.panel]) == .openRequested)
    }

    @Test("material background; buttons act on the first click (design §7.2)")
    func materialAndFirstMouse() {
        let controller = makeController()
        defer { controller.panel.close() }
        #expect(controller.panel.contentView is NSVisualEffectView)
        #expect(PanelHostingView(rootView: Text("Pause")).acceptsFirstMouse(for: nil))
    }

    @Test("the expand button toggles compact ↔ expanded")
    func toggleExpanded() {
        let controller = makeController()
        defer { controller.panel.close() }
        #expect(!controller.isExpanded)
        controller.toggleExpanded()
        #expect(controller.isExpanded)
        controller.toggleExpanded()
        #expect(!controller.isExpanded)
    }
}
