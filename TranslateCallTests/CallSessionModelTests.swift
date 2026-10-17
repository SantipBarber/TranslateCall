import Foundation
import Testing
@testable import TranslateCall

/// A CallSessionModel over a mock-backed coordinator and view model (no hardware, no models).
@MainActor
struct SessionHarness {
    let mocks = CoordinatorMocks()
    let coordinator: AudioCoordinator
    let viewModel: AudioViewModel
    let session: CallSessionModel
    let clock = TestClock()
    /// Times the main window was brought up for an alert (P27).
    let windowOpens = CallCounter()

    init(packsInstalled: Bool = true) {
        let mocks = self.mocks
        coordinator = AudioCoordinator(
            audioCapture: mocks.mockAudioCapture, systemCapture: mocks.mockSystemCapture,
            outgoingVADFactory: { mocks.mockVADFactory }, incomingVADFactory: { mocks.mockIncomingVAD },
            outgoingSTTFactory: { _ in mocks.mockOutgoingSTT }, incomingSTTFactory: { _ in mocks.mockIncomingSTT },
            outgoingTranslationService: mocks.mockOutgoingTranslation,
            incomingTranslationService: mocks.mockIncomingTranslation,
            outgoingTTSFactory: { _, _ in mocks.mockOutgoingTTS }, incomingTTSFactory: { _, _ in mocks.mockIncomingTTS },
            languagePairManager: mocks.languagePairManager,
            echoGateClock: TestClock(), noticeClock: TestClock(),
            isTranslationPairInstalled: { _, _ in packsInstalled }
        )
        let audioManager = AudioManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                                        configure: { _, _ in })
        viewModel = AudioViewModel(
            coordinator: coordinator, audioManager: audioManager, languagePairManager: mocks.languagePairManager,
            setupManager: SetupManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!),
            conversationSettings: ConversationSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        )
        let windowOpens = windowOpens
        session = CallSessionModel(coordinator: coordinator, viewModel: viewModel, clock: clock,
                                   openMainWindow: { windowOpens.increment() })
    }
}

/// Zoom installed and not running, on a monitor paced by a `TestClock`.
@MainActor
private func zoomNotRunning() -> (workspace: FakeWorkspace, monitor: CallAppMonitor, clock: TestClock) {
    let workspace = FakeWorkspace()
    workspace.installed = ["us.zoom.xos": "zoom.us"]
    let clock = TestClock()
    return (workspace, CallAppMonitor(workspace: workspace, clock: clock), clock)
}

@Suite("CallSessionModel (M9 UI core)", .serialized) @MainActor
struct CallSessionModelTests {

    @Test("phase, direction states and the title follow the coordinator")
    func derivesFromCoordinator() async {
        let harness = SessionHarness()
        await harness.coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { harness.session.phase == .running })
        #expect(harness.session.title == .translating)
        #expect(harness.session.sessionStartedAt != nil)

        await harness.mocks.mockIncomingVAD.injectVADState(true)
        #expect(await waitUntil { harness.session.incoming == .hearing })

        await harness.session.togglePause()
        #expect(await waitUntil { harness.session.outgoing == .paused && harness.session.title == .paused })
        await harness.session.togglePause()
        #expect(await waitUntil { !harness.session.isPaused })

        await harness.session.stop()
        #expect(await waitUntil { harness.session.phase == .idle })
    }

    @Test("a stopped capture makes the title Partly working")
    func partlyWorking() async {
        let harness = SessionHarness()
        await harness.mocks.mockSystemCapture.setThrowOnActivate(
            SystemAudioCaptureError.targetNotFound(bundleID: "com.test.call"))
        await harness.coordinator.start(captureTarget: .app(bundleID: "com.test.call"))
        #expect(await waitUntil { harness.session.title == .partlyWorking })
        #expect(harness.session.incoming == .unavailable(.targetNotFound(bundleID: "com.test.call")))
        await harness.session.stop()
    }

    @Test("an alert raised mid-call becomes an 8 s notice, never a modal (REQ-UI-82)")
    func midCallAlertBecomesNotice() async {
        let harness = SessionHarness()
        await harness.coordinator.start()
        #expect(await waitUntil { harness.session.phase == .running })

        harness.coordinator.errorAlert = AlertItem(title: "Error", message: "Something broke", action: nil)
        #expect(await waitUntil { harness.session.panelNotice == "Something broke" })
        #expect(harness.viewModel.errorAlert == nil)
        #expect(harness.session.notices == ["Something broke"])

        #expect(await waitUntil { harness.clock.sleeperCount > 0 })
        harness.clock.advance(by: .seconds(8))
        #expect(await waitUntil { harness.session.panelNotice == nil })
        #expect(harness.session.notices.isEmpty)
        await harness.session.stop()
    }

    @Test("an alert from a start that does not go active stays an alert and brings up the main window once (REQ-UI-36)")
    func failedStartKeepsAlert() async {
        let harness = SessionHarness(packsInstalled: false)
        await harness.coordinator.start()
        #expect(harness.viewModel.errorAlert?.title == "Languages Not Downloaded")
        #expect(await waitUntil { harness.windowOpens.value == 1 })
        #expect(harness.viewModel.errorAlert != nil)
        #expect(harness.session.panelNotice == nil)

        harness.viewModel.conversationSettings.listeningMode = .speakers   // any later recompute
        #expect(await waitUntil { !harness.session.notices.isEmpty })
        #expect(harness.windowOpens.value == 1, "once per alert")
    }

    @Test("Review focus: an error raised while starting, by a session that goes active, is a notice (REQ-UI-36)")
    func startErrorOfActiveSessionIsNotice() async {
        let harness = SessionHarness()
        await harness.mocks.mockOutgoingSTT.setThrowOnActivate(CocoaError(.featureUnsupported))   // STT fails, session goes on
        await harness.coordinator.start()
        #expect(harness.coordinator.isOutgoingActive)
        #expect(await waitUntil { harness.session.panelNotice != nil })
        #expect(harness.viewModel.errorAlert == nil)
        await harness.session.stop()
    }

    @Test("Review focus: the call app never launches → the session starts anyway after the timeout")
    func startAfterLaunchTimeout() async {
        let harness = SessionHarness()
        let (workspace, monitor, clock) = zoomNotRunning()
        let start = Task { await harness.session.start(launching: monitor.rows[0], monitor: monitor,
                                                       timeout: .milliseconds(400)) }
        for _ in 0..<2 {
            #expect(await waitUntil { clock.sleeperCount == 1 })
            clock.advance(by: .milliseconds(200))
        }
        await start.value
        #expect(workspace.openedApps.count == 1)
        #expect(harness.coordinator.isOutgoingActive)
        await harness.session.stop()
    }

    @Test("Fix R29: a session started elsewhere while the call app launches is not stopped when the wait ends")
    func startedElsewhereWhileLaunching() async {
        let harness = SessionHarness()
        let (workspace, monitor, clock) = zoomNotRunning()
        let launch = Task { await harness.session.start(launching: monitor.rows[0], monitor: monitor) }
        #expect(await waitUntil { clock.sleeperCount == 1 })
        await harness.coordinator.start()   // e.g. the menu bar's right-click Start
        #expect(harness.coordinator.isOutgoingActive)
        workspace.setRunning("us.zoom.xos", true)
        clock.advance(by: .milliseconds(200))
        await launch.value
        #expect(harness.coordinator.isOutgoingActive, "the wait's end must not toggle the session off")
        #expect(await waitUntil { harness.session.phase == .running })
        await harness.session.stop()
    }

    @Test("Fix R30: the newest transient notice wins and the panel notice outlives an older TTS line")
    func newestNoticeWins() async {
        let harness = SessionHarness()
        await harness.coordinator.start()
        #expect(await waitUntil { harness.session.phase == .running })
        harness.coordinator.ttsNotice = "1 sentence skipped"
        #expect(await waitUntil { harness.session.notices.last == "1 sentence skipped" })

        harness.coordinator.errorAlert = AlertItem(title: "Error", message: "Something broke", action: nil)
        #expect(await waitUntil { harness.session.panelNotice == "Something broke" })
        harness.coordinator.isSpeechActive = true   // any later coordinator change
        #expect(await waitUntil { harness.session.outgoing == .hearing })
        #expect(harness.session.notices.last == "Something broke")

        harness.coordinator.ttsNotice = nil
        #expect(await waitUntil { harness.session.notices.last == "Something broke" })
        harness.coordinator.isSpeechActive = false
        #expect(await waitUntil { harness.session.outgoing == .listening })
        #expect(harness.session.notices.last == "Something broke", "still live until its 8 s expiry")

        #expect(await waitUntil { harness.clock.sleeperCount > 0 })
        harness.clock.advance(by: .seconds(8))
        #expect(await waitUntil { harness.session.notices.isEmpty })
        await harness.session.stop()
    }

    @Test("speakers mode adds the standing line first")
    func speakersLine() {
        let lines = CallSessionModel.composeNotices(listeningMode: .speakers, transient: "1 sentence skipped")
        #expect(lines == ["Your mic pauses while their translation plays (speakers on)", "1 sentence skipped"])
        #expect(CallSessionModel.composeNotices(listeningMode: .headphones, transient: nil).isEmpty)
    }

    @Test("elapsed time is mm:ss, h:mm:ss past an hour")
    func elapsed() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(CallSessionModel.elapsedText(from: start, to: start.addingTimeInterval(724)) == "12:04")
        #expect(CallSessionModel.elapsedText(from: start, to: start.addingTimeInterval(3_725)) == "1:02:05")
    }

    @Test("Start with the call app closed opens it, waits until it runs, then starts (REQ-UI-34)")
    func startLaunchesApp() async {
        let harness = SessionHarness()
        let (workspace, monitor, clock) = zoomNotRunning()
        let start = Task { await harness.session.start(launching: monitor.rows[0], monitor: monitor) }
        #expect(await waitUntil { clock.sleeperCount == 1 })
        #expect(harness.session.phase == .launching)
        workspace.setRunning("us.zoom.xos", true)
        clock.advance(by: .milliseconds(200))
        await start.value
        #expect(workspace.openedApps.count == 1)
        #expect(harness.coordinator.isOutgoingActive)
        await harness.session.stop()
    }

    @Test("Review focus: a second Start while the call app launches is ignored, not a Stop (REQ-UI-34)")
    func secondStartWhileLaunching() async {
        let harness = SessionHarness()
        let (workspace, monitor, clock) = zoomNotRunning()
        let first = Task { await harness.session.start(launching: monitor.rows[0], monitor: monitor) }
        #expect(await waitUntil { clock.sleeperCount == 1 })
        await harness.session.start(launching: monitor.rows[0], monitor: monitor)   // returns at once
        #expect(workspace.openedApps.count == 1)
        workspace.setRunning("us.zoom.xos", true)
        clock.advance(by: .milliseconds(200))
        await first.value
        #expect(await waitUntil { harness.session.phase == .running })
        await harness.session.stop()
    }

    @Test("a fresh install reads Show the status panel and Show latency as on: registered at launch (REQ-UI-40)")
    func settingsDefaultOn() {
        // The registration domain is process-wide: the test host's AppContainer registered it at launch.
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!   // nothing stored
        #expect(defaults.bool(forKey: UISettingsKeys.showStatusPanel))
        #expect(defaults.bool(forKey: UISettingsKeys.showLatency))
        defaults.set(false, forKey: UISettingsKeys.showStatusPanel)
        #expect(!defaults.bool(forKey: UISettingsKeys.showStatusPanel), "the user's choice wins")
    }

    @Test("the latency label is hidden in production: the provider has nothing")
    func noLatency() {
        let provider = NoLatencyProvider()
        #expect(!provider.canProvide)
        #expect(provider.latestLatency(for: .outgoing) == nil)
        #expect(Duration.milliseconds(900).latencyLabel == "0.9 s")
    }
}
