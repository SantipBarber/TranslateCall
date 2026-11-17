import Foundation
import Testing
@testable import TranslateCall

@MainActor
private final class FakePermissionRequester: PermissionRequesting {
    var micGranted = false
    private(set) var panes: [PrivacyPane] = []
    func requestMicrophone() async -> Bool { micGranted }
    func requestScreenRecording() {}
    func openPrivacyPane(_ pane: PrivacyPane) { panes.append(pane) }
    func relaunch() {}
}

@Suite("PermissionRequester (REQ-FR-11, 12)")
@MainActor
struct PermissionRequesterTests {
    @Test("privacyPaneURLs: the exact System Settings URLs")
    func privacyPaneURLs() {
        #expect(PrivacyPane.microphone.url.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #expect(PrivacyPane.screenRecording.url.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @Test("micRequestReportsGrant: the requester's answer reaches the caller")
    func micRequestReportsGrant() async {
        let fake = FakePermissionRequester()
        let requester: any PermissionRequesting = fake
        #expect(await requester.requestMicrophone() == false)
        fake.micGranted = true
        #expect(await requester.requestMicrophone() == true)
        requester.openPrivacyPane(.microphone)
        #expect(fake.panes == [.microphone])
    }

    @Test("the reopen-setup mark is one-shot")
    func reopenFlagIsOneShot() {
        let defaults = ScratchDefaults.make("SetupReopenFlag")
        #expect(!SetupReopenFlag.consume(in: defaults))
        SetupReopenFlag.set(in: defaults)
        #expect(defaults.bool(forKey: "tlk.setup.reopen"))
        #expect(SetupReopenFlag.consume(in: defaults))
        #expect(!SetupReopenFlag.consume(in: defaults))
    }
}
