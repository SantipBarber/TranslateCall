import SwiftUI

/// Listening mode on the left, Settings on the right; both open Settings (REQ-UI-09).
struct SetupFooter: View {
    @ObservedObject var settings: ConversationSettings

    var body: some View {
        HStack {
            Button { SettingsOpener.shared.open(tab: .general) } label: {
                switch settings.listeningMode {
                case .headphones: Label("Headphones", systemImage: "headphones")
                case .speakers: Label("Speakers", systemImage: "hifispeaker")
                }
            }
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
