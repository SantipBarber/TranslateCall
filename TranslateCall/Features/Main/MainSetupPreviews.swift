#if DEBUG
import SwiftUI

/// A workspace with every catalog app installed and a chosen set running, for previews.
@MainActor
private final class FixtureWorkspace: WorkspaceProviding {
    let changes = AsyncStream<Void> { _ in }
    let running: Set<String>
    init(running: Set<String>) { self.running = running }
    private let installed: Set<String> = ["com.microsoft.teams2", "us.zoom.xos", "com.apple.FaceTime"]
    func urlForApplication(bundleID: String) -> URL? {
        installed.contains(bundleID) ? URL(fileURLWithPath: "/Applications/\(bundleID).app") : nil
    }
    func defaultBrowserURL() -> URL? { URL(fileURLWithPath: "/Applications/Chrome.app") }
    func bundleID(ofAppAt url: URL) -> String? { "com.google.Chrome" }
    func displayName(ofAppAt url: URL) -> String { "Chrome" }
    func runningBundleIDs() -> Set<String> { running }
    func runningRegularApps() -> [(bundleID: String, name: String)] { [] }
    func openApplication(at url: URL) async throws {}
    func open(_ url: URL) {}
}

/// One state of the setup window, fixture-driven (previews never start a real session).
@MainActor
struct MainSetupFixture {
    var pair: PairReadiness = .ready
    var permissions = PermissionState.allGranted
    var teamsRunning = true
    var target = "de"
    var cloning = true

    var content: some View {
        let monitor = CallAppMonitor(workspace: FixtureWorkspace(
            running: teamsRunning ? ["com.microsoft.teams2", "com.google.Chrome"] : ["com.google.Chrome"]))
        let teams = monitor.rows.first { $0.callAppID == "teams" }
        let defaults = UserDefaults(suiteName: "preview-\(UUID().uuidString)") ?? .standard
        defaults.set("es", forKey: "tlk.source.language")
        defaults.set(target, forKey: "tlk.target.language")
        let languages = LanguagePairManager(defaults: defaults, languageLoader: {
            ["es", "en", "de", "fr", "pt"].map { Locale.Language(identifier: $0) }
        })
        let selector = TTSEngineSelector(defaults: defaults)
        selector.voiceCloningEnabled = cloning
        let profile = VoiceProfileHeader(
            id: UUID(), name: "Santi", createdAt: Date(timeIntervalSince1970: 1_760_000_000), durationSeconds: 20,
            sampleRate: 24_000, sampleCount: 480_000,
            quality: VoiceQualityMetrics(peakRmsDbfs: -20, hasClipping: false, voicedDurationSeconds: 18,
                                         grade: .good),
            formatVersion: 1)
        let readiness = Readiness.derive(permissions: permissions, blackHolePresent: true, pair: pair,
                                         app: teams, phase: .idle)
        return MainSetupContent(
            readiness: readiness, pair: pair, isLocked: false, monitor: monitor,
            selectedBundleID: teams?.bundleID, languages: languages, sttSelector: STTEngineSelector(defaults: defaults),
            ttsSelector: selector, conversationSettings: ConversationSettings(defaults: defaults),
            profile: profile, actions: MainSetupActions()
        )
        .background(Color(.windowBackgroundColor))
    }
}

#Preview("Ready — light") { MainSetupFixture().content }
#Preview("Ready — dark") { MainSetupFixture().content.preferredColorScheme(.dark) }
#Preview("Language not downloaded — light") { MainSetupFixture(pair: .missing(language: "Deutsch")).content }
#Preview("Language not downloaded — dark") {
    MainSetupFixture(pair: .missing(language: "Deutsch")).content.preferredColorScheme(.dark)
}
#Preview("Call app not open — light") { MainSetupFixture(teamsRunning: false).content }
#Preview("Call app not open — dark") { MainSetupFixture(teamsRunning: false).content.preferredColorScheme(.dark) }
#Preview("Permission missing — light") {
    MainSetupFixture(permissions: PermissionState(microphone: .denied, screenRecording: .denied)).content
}
#Preview("Permission missing — dark") {
    MainSetupFixture(permissions: PermissionState(microphone: .denied, screenRecording: .denied)).content
        .preferredColorScheme(.dark)
}
#Preview("Voice unavailable — light") { MainSetupFixture(target: "th").content }
#Preview("Voice unavailable — dark") { MainSetupFixture(target: "th").content.preferredColorScheme(.dark) }
#endif
