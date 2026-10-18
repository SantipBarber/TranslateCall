import SwiftUI

/// One of "Your voices" (REQ-ST-20): name, subtitle, In use / Use, play and a "…" menu.
struct VoiceProfileRow: View {
    let profile: VoiceProfileHeader
    let isActive: Bool
    let onUse: () -> Void
    let onPlay: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).lineLimit(1).truncationMode(.tail)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: Theme.Spacing.small)
            if isActive {
                Text("In use")
                    .font(.caption).fontWeight(.medium).foregroundStyle(Theme.accent)
                    .padding(.horizontal, Theme.Spacing.small).padding(.vertical, 2)
                    .background(Theme.soft(Theme.accent), in: Capsule())
            } else {
                Button("Use", action: onUse).buttonStyle(.link)
                    .accessibilityLabel("Use \(profile.name)")
            }
            Button(action: onPlay) { Image(systemName: "play.circle") }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .accessibilityLabel("Play \(profile.name)")
            Menu {
                Button("Rename…", action: onRename)
                Button("Delete…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More for \(profile.name)")
        }
    }

    private var subtitle: String {
        let date = profile.createdAt.formatted(date: .abbreviated, time: .omitted)
        let seconds = Int(profile.durationSeconds.rounded())
        return String(localized: "recorded \(date) · \(seconds) s")
    }
}
