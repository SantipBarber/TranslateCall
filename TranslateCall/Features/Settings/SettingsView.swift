import SwiftUI

/// The Settings window (REQ-UI-70). The tab contents are filled in by later M9 UI core tasks.
struct SettingsView: View {
    @AppStorage(SettingsOpener.tabKey) private var tab = SettingsTab.general.rawValue
    @EnvironmentObject private var viewModel: AudioViewModel

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general.rawValue)
            LegacyAdvancedSettingsView(vadProvider: viewModel.vadProvider)
                .tabItem { Label("Advanced (legacy)", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.advancedLegacy.rawValue)
        }
        .frame(width: 560)
    }
}
