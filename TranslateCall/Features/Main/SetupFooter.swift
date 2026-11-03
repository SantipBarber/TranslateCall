import SwiftUI

/// Listening mode on the left, Settings on the right; both open Settings (REQ-UI-09).
struct SetupFooter: View {
    @ObservedObject var settings: ConversationSettings
    @ObservedObject var route: OutputRouteMonitor

    var body: some View {
        HStack {
            Button { SettingsOpener.shared.open(tab: .general) } label: {
                switch ListeningMode.effective(chosen: settings.listeningMode, route: route.route) {
                case .headphones: Label("Headphones", systemImage: "headphones")
                case .speakers where settings.listeningMode == .headphones:
                    Label("Speakers (detected)", systemImage: "hifispeaker")
                case .speakers: Label("Speakers", systemImage: "hifispeaker")
                }
            }
            .help("Your mic pauses while their translation plays when you listen on speakers")
            Spacer()
            Button { SettingsOpener.shared.open(tab: .general) } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
