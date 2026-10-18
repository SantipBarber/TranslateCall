import SwiftUI

/// The Settings window (REQ-UI-70). General, Voices and Advanced.
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
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.advanced)
        }
        .frame(width: 560)
    }
}
