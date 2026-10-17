import Darwin
import SwiftUI

@main
struct TranslateCallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @StateObject private var container = AppContainer()
    @State private var menuBarController: MenuBarController?

    var body: some Scene {
        WindowGroup(id: MainWindowOpener.windowID) {
            // Translation bridges live in AppContainer's TranslationHostWindow, not here (F8.5.4 D-2).
            MainSetupView()
            .environmentObject(container.audioViewModel)
            .environmentObject(container.languagePairManager)
            .environmentObject(container.setupManager)
            .environmentObject(container.voiceProfileManager)
            .environmentObject(container.audioViewModel.engineSelector)
            .environmentObject(container.audioViewModel.ttsEngineSelector)
            .environmentObject(container.uiServices.callSession)
            .environmentObject(container.uiServices.mainSetupModel)
            .onAppear {
                // Only now: a host on screen before this point stops SwiftUI opening this window (A26).
                container.translationHost.show()
                MainWindowOpener.shared.openWindow = { [openWindow] in openWindow(id: MainWindowOpener.windowID) }
                SettingsOpener.shared.openSettings = { [openSettings] in openSettings() }
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
            #if DEBUG
            CommandMenu("Debug") {
                Button("Toggle Test Status Panel") {
                    DebugStatusPanel.toggle()
                }
            }
            #endif
        }
        Settings {
            SettingsView()
                .environmentObject(container.audioViewModel)
                .environmentObject(container.languagePairManager)
                .environmentObject(container.setupManager)
                .environmentObject(container.voiceProfileManager)
                .environmentObject(container.audioViewModel.engineSelector)
                .environmentObject(container.audioViewModel.ttsEngineSelector)
                .environmentObject(container.uiServices.callSession)
                .environmentObject(container.uiServices.mainSetupModel)
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

#if DEBUG
/// A test panel for the manual focus check (M9 UI core Task 2 step 6); Task 17 deletes it.
@MainActor
enum DebugStatusPanel {
    static let controller = StatusPanelController(size: NSSize(width: 320, height: 120), autosaveName: nil) { _ in
        PanelHostingView(rootView: DebugStatusPanelContent())
    }

    static func toggle() {
        if controller.isVisible { controller.hide() } else { controller.show() }
    }
}

private struct DebugStatusPanelContent: View {
    var body: some View {
        Text("Status panel test").padding().frame(width: 320, height: 120)
    }
}
#endif
