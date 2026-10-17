import Testing
@testable import TranslateCall

@Suite("DirectionState (M9 UI core REQ-UI-43)")
struct DirectionStateTests {

    @Test("outgoing priority: paused > mic paused > speaking > translating > hearing > listening",
          arguments: [
            (true, true, true, true, true, DirectionState.paused),
            (false, true, true, true, true, .micPaused),
            (false, false, true, true, true, .speaking),
            (false, false, false, true, true, .translating),
            (false, false, false, false, true, .hearing),
            (false, false, false, false, false, .listening),
          ])
    func outgoingPriority(paused: Bool, micPaused: Bool, speaking: Bool, translating: Bool, speech: Bool,
                          expected: DirectionState) {
        #expect(DirectionState.outgoing(paused: paused, micPaused: micPaused, speaking: speaking,
                                        translating: translating, speech: speech) == expected)
    }

    @Test("incoming: a stopped capture wins over everything, even pause")
    func incomingUnavailableWins() {
        let state = DirectionState.incoming(status: .stopped(.targetNotFound(bundleID: "us.zoom.xos")), paused: true,
                                            speaking: true, translating: true, speech: true)
        #expect(state == .unavailable(.targetNotFound(bundleID: "us.zoom.xos")))
    }

    @Test("incoming active/starting/idle derive normally", arguments: [IncomingStatus.active, .starting, .idle])
    func incomingNormal(status: IncomingStatus) {
        #expect(DirectionState.incoming(status: status, paused: true, speaking: false, translating: false, speech: false)
                == .paused)
        #expect(DirectionState.incoming(status: status, paused: false, speaking: false, translating: true, speech: true)
                == .translating)
        #expect(DirectionState.incoming(status: status, paused: false, speaking: false, translating: false, speech: false)
                == .listening)
    }

    @Test("panel title: Starting… > Partly working > Paused > Translating")
    func panelTitle() {
        let lost = DirectionState.unavailable(.permissionDenied)
        #expect(PanelTitle.derive(isStarting: true, isPaused: true, incoming: lost) == .starting)
        #expect(PanelTitle.derive(isStarting: false, isPaused: true, incoming: lost) == .partlyWorking)
        #expect(PanelTitle.derive(isStarting: false, isPaused: true, incoming: .listening) == .paused)
        #expect(PanelTitle.derive(isStarting: false, isPaused: false, incoming: .speaking) == .translating)
        #expect(PanelTitle.translating.text == "Translating")
    }
}
