import SwiftUI

/// The Settings window (REQ-UI-70). Only General for now; M9 UI settings Tasks 10, 12 and 14 add the others.
struct SettingsView: View {
    @AppStorage(SettingsOpener.tabKey) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        .frame(width: 560)
    }
}
