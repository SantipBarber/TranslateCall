import AppKit
import Combine
import Foundation

// MARK: - WorkspaceProviding

/// The parts of `NSWorkspace` the call-app list needs; tests use a fake.
protocol WorkspaceProviding: AnyObject {
    func urlForApplication(bundleID: String) -> URL?
    /// The app that opens https links.
    func defaultBrowserURL() -> URL?
    func bundleID(ofAppAt url: URL) -> String?
    func displayName(ofAppAt url: URL) -> String
    func runningBundleIDs() -> Set<String>
    /// Regular (Dock) apps that are running, for "Other app…".
    func runningRegularApps() -> [(bundleID: String, name: String)]
    func openApplication(at url: URL) async throws
    func open(_ url: URL)
    /// Fires after any app launches or quits.
    var changes: AsyncStream<Void> { get }
}

// MARK: - CallAppMonitor

/// The installed call apps with their live running state (REQ-UI-02…04, design §6). Uses no
/// ScreenCaptureKit, so listing needs no screen-recording permission.
@MainActor
final class CallAppMonitor: ObservableObject {
    @Published private(set) var rows: [CallAppRow] = []
    @Published private(set) var runningBundleIDs: Set<String> = []

    private let workspace: any WorkspaceProviding
    /// A persisted choice outside the catalog ("Other app…"): kept as a row.
    private var extraBundleID: String?
    private var observation: Task<Void, Never>?
    /// Paces `waitUntilRunning`; tests inject a `TestClock`.
    private let clock: any Clock<Duration>

    init(workspace: any WorkspaceProviding, selectedBundleID: String? = nil,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.workspace = workspace
        self.clock = clock
        extraBundleID = selectedBundleID
        refresh()
        let changes = workspace.changes
        observation = Task { [weak self] in
            for await _ in changes { self?.refresh() }
        }
    }

    deinit { observation?.cancel() }

    /// Rebuilds the rows from what is installed and running now.
    func refresh() {
        runningBundleIDs = workspace.runningBundleIDs()
        var result = CallApp.catalog.compactMap(row(for:))
        if let extra = extraBundleID, !result.contains(where: { $0.bundleID == extra }) {
            result.append(otherRow(bundleID: extra))
        }
        rows = result
    }

    /// Keeps an "Other app…" choice visible in the list.
    func setSelected(bundleID: String?) {
        extraBundleID = bundleID
        refresh()
    }

    func runningRegularApps() -> [(bundleID: String, name: String)] {
        workspace.runningRegularApps()
    }

    /// Launches the app (Meet: opens the page in the default browser). Does not start translation.
    func open(_ row: CallAppRow) async {
        if let url = row.openURL {
            workspace.open(url)
        } else if let appURL = row.appURL {
            try? await workspace.openApplication(at: appURL)
        }
    }

    /// True once `bundleID` runs, false after `timeout` on the monitor's clock (REQ-UI-34). Polls
    /// as well as listening, so a missed launch notification cannot make it wait for the whole timeout.
    func waitUntilRunning(bundleID: String, timeout: Duration,
                          pollEvery: Duration = .milliseconds(200)) async -> Bool {
        var waited = Duration.zero
        while true {
            refresh()
            if runningBundleIDs.contains(bundleID) { return true }
            guard waited < timeout else { return false }
            do { try await clock.sleep(for: pollEvery) } catch { return false }
            waited += pollEvery
        }
    }

    // MARK: Rows

    private func row(for app: CallApp) -> CallAppRow? {
        switch app.kind {
        case .native:
            for bundleID in app.bundleIDs {
                guard let url = workspace.urlForApplication(bundleID: bundleID) else { continue }
                return CallAppRow(bundleID: bundleID, title: app.displayName, appName: app.displayName,
                                  callAppID: app.id, symbol: app.symbol, appURL: url, openURL: nil,
                                  isRunning: runningBundleIDs.contains(bundleID))
            }
            return nil
        case .browser(let page):
            guard let browser = workspace.defaultBrowserURL(),
                  let bundleID = workspace.bundleID(ofAppAt: browser) else { return nil }
            let title = "\(app.displayName) · \(workspace.displayName(ofAppAt: browser))"
            return CallAppRow(bundleID: bundleID, title: title, appName: app.displayName, callAppID: app.id,
                              symbol: app.symbol, appURL: browser, openURL: page,
                              isRunning: runningBundleIDs.contains(bundleID))
        }
    }

    private func otherRow(bundleID: String) -> CallAppRow {
        let url = workspace.urlForApplication(bundleID: bundleID)
        let name = url.map(workspace.displayName(ofAppAt:)) ?? bundleID
        return CallAppRow(bundleID: bundleID, title: name, appName: name, callAppID: nil, symbol: "app",
                          appURL: url, openURL: nil, isRunning: runningBundleIDs.contains(bundleID))
    }
}

// MARK: - LiveWorkspace

/// `NSWorkspace`-backed provider.
final class LiveWorkspace: WorkspaceProviding {
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var tokens: [NSObjectProtocol] = []

    init() {
        (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [continuation] _ in
                continuation.yield()
            })
        }
    }

    func urlForApplication(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func defaultBrowserURL() -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: CallApp.meetURL)
    }

    func bundleID(ofAppAt url: URL) -> String? { Bundle(url: url)?.bundleIdentifier }

    func displayName(ofAppAt url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func runningRegularApps() -> [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func openApplication(at url: URL) async throws {
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
