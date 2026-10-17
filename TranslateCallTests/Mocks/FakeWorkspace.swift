import Foundation
@testable import TranslateCall

/// In-memory `WorkspaceProviding`: installed apps by bundle ID, a running set, a default browser.
@MainActor
final class FakeWorkspace: WorkspaceProviding {
    var installed: [String: String] = [:]          // bundle ID → display name
    var running: Set<String> = []
    var defaultBrowser: String?                     // bundle ID
    private(set) var openedApps: [URL] = []
    private(set) var openedURLs: [URL] = []
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Simulates a launch or quit notification.
    func setRunning(_ bundleID: String, _ isRunning: Bool) {
        if isRunning { running.insert(bundleID) } else { running.remove(bundleID) }
        continuation.yield()
    }

    func urlForApplication(bundleID: String) -> URL? {
        installed[bundleID].map { _ in URL(fileURLWithPath: "/Applications/\(bundleID).app") }
    }
    func defaultBrowserURL() -> URL? { defaultBrowser.flatMap(urlForApplication(bundleID:)) }
    func bundleID(ofAppAt url: URL) -> String? { url.deletingPathExtension().lastPathComponent }
    func displayName(ofAppAt url: URL) -> String { installed[bundleID(ofAppAt: url) ?? ""] ?? "?" }
    func runningBundleIDs() -> Set<String> { running }
    func runningRegularApps() -> [(bundleID: String, name: String)] {
        running.sorted().map { ($0, installed[$0] ?? $0) }
    }
    func openApplication(at url: URL) async throws { openedApps.append(url) }
    func open(_ url: URL) { openedURLs.append(url) }
}
