import Testing
@testable import TranslateCall

@Suite("IncomingStatusBanner") @MainActor
struct IncomingStatusBannerTests {
    @Test("hidden when idle or active")
    func hidden() {
        #expect(IncomingStatusBanner.text(for: .idle) == nil)
        #expect(IncomingStatusBanner.text(for: .active) == nil)
    }

    @Test("texts and Retry visibility per status")
    func texts() {
        #expect(IncomingStatusBanner.text(for: .disabled) == "Incoming off — choose the call app above")
        #expect(IncomingStatusBanner.text(for: .starting) == "Connecting to call audio…")
        let stopped = IncomingStatus.stopped(.targetNotFound(bundleID: "us.zoom.xos"))
        #expect(IncomingStatusBanner.text(for: stopped) == "Incoming stopped: The call app (us.zoom.xos) is not running.")
        #expect(IncomingStatusBanner.showsRetry(stopped))
        #expect(!IncomingStatusBanner.showsRetry(.disabled))
        #expect(!IncomingStatusBanner.showsRetry(.starting))
    }
}
