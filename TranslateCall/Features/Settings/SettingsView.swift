import SwiftUI

/// The Settings window (REQ-UI-70). General and Voices for now; M9 UI settings Task 14 adds Advanced.
struct SettingsView: View {
    @AppStorage(SettingsOpener.tabKey) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            VoicesSettingsView()
                .tabItem { Label("Voices", systemImage: "waveform") }
                .tag(SettingsTab.voices)
        }
        .frame(width: 560)
    }
}
