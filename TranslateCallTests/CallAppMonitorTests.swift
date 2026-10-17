import Foundation
import Testing
@testable import TranslateCall

@Suite("CallAppMonitor (M9 UI core REQ-UI-02…04, 34)", .serialized) @MainActor
struct CallAppMonitorTests {

    private func workspace() -> FakeWorkspace {
        let fake = FakeWorkspace()
        fake.installed = ["us.zoom.xos": "zoom.us", "com.microsoft.teams2": "Microsoft Teams",
                          "com.google.Chrome": "Google Chrome", "com.apple.FaceTime": "FaceTime"]
        fake.defaultBrowser = "com.google.Chrome"
        return fake
    }

    @Test("only installed apps, in catalog order; Meet maps to the default browser")
    func rowsForInstalledApps() {
        let monitor = CallAppMonitor(workspace: workspace())
        #expect(monitor.rows.map(\.title) == ["Microsoft Teams", "Zoom", "Google Meet · Google Chrome", "FaceTime"])
        let meet = monitor.rows[2]
        #expect(meet.bundleID == "com.google.Chrome")
        #expect(meet.appName == "Google Meet")
        #expect(meet.openURL == CallApp.meetURL)
    }

    @Test("Teams classic is used when only it is installed")
    func olderBundleID() {
        let fake = FakeWorkspace()
        fake.installed = ["com.microsoft.teams": "Microsoft Teams classic"]
        #expect(CallAppMonitor(workspace: fake).rows.map(\.bundleID) == ["com.microsoft.teams"])
    }

    @Test("running state updates live on launch and quit")
    func liveRunningState() async {
        let fake = workspace()
        let monitor = CallAppMonitor(workspace: fake)
        #expect(monitor.rows.first { $0.bundleID == "us.zoom.xos" }?.isRunning == false)
        fake.setRunning("us.zoom.xos", true)
        #expect(await waitUntil { monitor.rows.first { $0.bundleID == "us.zoom.xos" }?.isRunning == true })
        fake.setRunning("us.zoom.xos", false)
        #expect(await waitUntil { monitor.rows.first { $0.bundleID == "us.zoom.xos" }?.isRunning == false })
    }

    @Test("a persisted choice outside the catalog stays as its own row")
    func otherAppKept() {
        let fake = workspace()
        fake.installed["com.example.Call"] = "Example Call"
        let monitor = CallAppMonitor(workspace: fake, selectedBundleID: "com.example.Call")
        #expect(monitor.rows.last?.title == "Example Call")
        #expect(monitor.rows.last?.callAppID == nil)
        monitor.setSelected(bundleID: "us.zoom.xos")
        #expect(!monitor.rows.contains { $0.bundleID == "com.example.Call" })
    }

    @Test("Open launches the app, or opens the Meet page in the browser")
    func openApps() async {
        let fake = workspace()
        let monitor = CallAppMonitor(workspace: fake)
        await monitor.open(monitor.rows[1])
        await monitor.open(monitor.rows[2])
        #expect(fake.openedApps.map(\.lastPathComponent) == ["us.zoom.xos.app"])
        #expect(fake.openedURLs == [CallApp.meetURL])
    }

    @Test("waitUntilRunning: false once the timeout has passed on the clock")
    func waitUntilRunningTimesOut() async {
        let clock = TestClock()
        let monitor = CallAppMonitor(workspace: workspace(), clock: clock)
        let wait = Task { await monitor.waitUntilRunning(bundleID: "us.zoom.xos", timeout: .milliseconds(400),
                                                         pollEvery: .milliseconds(200)) }
        for _ in 0..<2 {
            #expect(await waitUntil { clock.sleeperCount == 1 })
            clock.advance(by: .milliseconds(200))
        }
        #expect(await wait.value == false)
    }

    @Test("waitUntilRunning: true at the first poll after the app runs")
    func waitUntilRunningSucceeds() async {
        let clock = TestClock()
        let fake = workspace()
        let monitor = CallAppMonitor(workspace: fake, clock: clock)
        let wait = Task { await monitor.waitUntilRunning(bundleID: "us.zoom.xos", timeout: .seconds(15)) }
        #expect(await waitUntil { clock.sleeperCount == 1 })
        fake.running.insert("us.zoom.xos")   // no notification: the poll alone must find it
        clock.advance(by: .milliseconds(200))
        #expect(await wait.value == true)
    }
}
