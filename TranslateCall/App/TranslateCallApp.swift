import Darwin
import SwiftUI

@main
struct TranslateCallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var container = AppContainer()
    @State private var menuBarController: MenuBarController?

    var body: some Scene {
        WindowGroup(id: MainWindowOpener.windowID) {
            // Translation bridges live in AppContainer's TranslationHostWindow, not here (F8.5.4 D-2).
            ContentView()
            .environmentObject(container.audioViewModel)
            .environmentObject(container.languagePairManager)
            .environmentObject(container.setupManager)
            .environmentObject(container.voiceProfileManager)
            .environmentObject(container.audioViewModel.engineSelector)
            .environmentObject(container.audioViewModel.ttsEngineSelector)
            .onAppear {
                MainWindowOpener.shared.openWindow = { [openWindow] in openWindow(id: MainWindowOpener.windowID) }
                guard menuBarController == nil else { return }
                menuBarController = MenuBarController(viewModel: container.audioViewModel)
            }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .help) {
                Button("Send Feedback…") {
                    openFeedbackURL()
                }
            }
        }
    }

    // MARK: - Feedback

    private func openFeedbackURL() {
        let version = appVersion
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let model = hardwareModel()

        let body = """
        **App Version**: \(version)
        **macOS**: \(osVersion)
        **Hardware**: \(model)

        ### Description
        <!-- What happened? -->

        ### Steps to Reproduce
        <!-- Step by step... -->

        ### Expected Behaviour
        <!-- What should have happened? -->

        ### Actual Behaviour
        <!-- What actually happened? -->
        """

        guard let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://github.com/spbarber/TranslateCall/issues/new?body=\(encoded)") else {
            if let fallbackURL = URL(string: "https://github.com/spbarber/TranslateCall/issues") {
                NSWorkspace.shared.open(fallbackURL)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    private func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(bytes: buffer.prefix(while: { $0 != 0 }), encoding: .utf8)
            ?? "unknown"
    }
}
