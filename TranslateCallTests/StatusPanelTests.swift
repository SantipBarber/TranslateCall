import AppKit
import SwiftUI
import Testing
@testable import TranslateCall

@Suite("StatusPanel (M9 UI core REQ-UI-41)") @MainActor
struct StatusPanelTests {

    private func makeController() -> StatusPanelController {
        StatusPanelController(size: NSSize(width: 320, height: 174), autosaveName: nil,
                              visibleFrames: { [NSRect(x: 0, y: 0, width: 1440, height: 875)] }) { _ in NSView() }
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

    // MARK: Restoring the position

    private let screen = NSRect(x: 0, y: 25, width: 1440, height: 850)
    private let size = NSSize(width: 320, height: 174)

    @Test("a saved top-left restores the frame hanging from it")
    func restoresFromTopLeft() {
        let frame = StatusPanel.restoredFrame(topLeft: NSPoint(x: 500, y: 700), size: size, visibleFrames: [screen])
        #expect(frame == NSRect(x: 500, y: 700 - 174, width: 320, height: 174))
    }

    @Test("a point off the screen is clamped inside the visible frame")
    func clampsToVisibleFrame() {
        let right = StatusPanel.restoredFrame(topLeft: NSPoint(x: 5000, y: 5000), size: size, visibleFrames: [screen])
        #expect(right == NSRect(x: 1440 - 320, y: 875 - 174, width: 320, height: 174))
        let low = StatusPanel.restoredFrame(topLeft: NSPoint(x: -400, y: -50), size: size, visibleFrames: [screen])
        #expect(low == NSRect(x: 0, y: 25, width: 320, height: 174))
    }

    @Test("with a second screen the point picks its own screen")
    func picksTheScreenHoldingThePoint() {
        let second = NSRect(x: 1440, y: 0, width: 1920, height: 1055)
        let frame = StatusPanel.restoredFrame(topLeft: NSPoint(x: 1500, y: 900), size: size,
                                              visibleFrames: [screen, second])
        #expect(frame == NSRect(x: 1500, y: 900 - 174, width: 320, height: 174))
    }

    @Test("nothing saved or no screen: no restored frame")
    func noRestore() {
        #expect(StatusPanel.restoredFrame(topLeft: nil, size: size, visibleFrames: [screen]) == nil)
        #expect(StatusPanel.restoredFrame(topLeft: NSPoint(x: 1, y: 1), size: size, visibleFrames: []) == nil)
    }

    @Test("moving the panel saves its top-left; a new controller restores it, still compact")
    func persistsTopLeft() throws {
        let defaults = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        let first = StatusPanelController(size: size, autosaveName: "T", defaults: defaults,
                                          visibleFrames: { [screen] }) { _ in NSView() }
        defer { first.panel.close() }
        first.resize(to: NSSize(width: 320, height: 380))   // expanded when the app quits
        first.panel.setFrameOrigin(NSPoint(x: 300, y: 200))
        let second = StatusPanelController(size: size, autosaveName: "T", defaults: defaults,
                                           visibleFrames: { [screen] }) { _ in NSView() }
        defer { second.panel.close() }
        #expect(second.panel.frame.maxY == 580)
        #expect(second.panel.frame.minX == 300)
        #expect(second.panel.frame.size == size)
    }

    @Test("the blur is clipped by a resizable mask image, not a layer radius")
    func roundedMask() throws {
        let background = try #require(makeController().panel.contentView as? NSVisualEffectView)
        let mask = try #require(background.maskImage)
        #expect(mask.capInsets.top == 12 && mask.capInsets.left == 12)
        #expect(background.frame.size == size)
    }

    // MARK: Session binding and copy

    @Test("the panel shows while the session runs and hides when it ends; off, it stays hidden (REQ-UI-40/47)")
    func followsTheSession() async throws {
        let on = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        UISettingsKeys.registerDefaults(in: on)
        let harness = SessionHarness()
        let controller = makeController()
        defer { controller.panel.close() }
        controller.bind(to: harness.session, defaults: on)
        await harness.coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { controller.isVisible })
        await harness.session.stop()
        #expect(await waitUntil { !controller.isVisible })

        let off = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        off.set(false, forKey: UISettingsKeys.showStatusPanel)
        let other = makeController()
        defer { other.panel.close() }
        other.bind(to: harness.session, defaults: off)
        await harness.coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { harness.session.phase == .running })
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { continuation.resume() } }
        #expect(!other.isVisible)
        await harness.session.stop()
    }

    @Test("turning Show the status panel off mid-call hides the panel; on again shows it (REQ-UI-40)")
    func settingFollowedMidCall() async throws {
        let defaults = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        UISettingsKeys.registerDefaults(in: defaults)
        let harness = SessionHarness()
        let controller = makeController()
        defer { controller.panel.close() }
        controller.bind(to: harness.session, defaults: defaults)
        await harness.coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { controller.isVisible })
        defaults.set(false, forKey: UISettingsKeys.showStatusPanel)
        #expect(await waitUntil { !controller.isVisible })
        defaults.set(true, forKey: UISettingsKeys.showStatusPanel)
        #expect(await waitUntil { controller.isVisible })
        await harness.session.stop()
        #expect(await waitUntil { !controller.isVisible })
    }

    @Test("quotes follow the language: «» Spanish, „“ German, “” English")
    func quotes() {
        #expect(PanelQuote.wrap("Hola", languageCode: "es") == "«Hola»")
        #expect(PanelQuote.wrap("Hallo", languageCode: "de") == "„Hallo“")
        #expect(PanelQuote.wrap("Hi", languageCode: "en") == "“Hi”")
        #expect(PanelQuote.wrap("Hi", languageCode: nil) == "“Hi”")
    }

    @Test("every state has the chip icon of the design")
    func chipIcons() {
        #expect(DirectionState.speaking.chipStyle.systemImage == "speaker.wave.2")
        #expect(DirectionState.listening.chipStyle.systemImage == "ear")
        #expect(DirectionState.hearing.chipStyle.systemImage == "waveform")
        #expect(DirectionState.translating.chipStyle.systemImage == "ellipsis")
        #expect(DirectionState.paused.chipStyle.systemImage == "pause")
        #expect(DirectionState.micPaused.chipStyle.systemImage == "mic.slash")
        #expect(DirectionState.unavailable(.targetNotFound(bundleID: "x")).chipStyle.systemImage == "speaker.slash")
    }
}
