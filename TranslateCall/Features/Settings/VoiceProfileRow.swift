import SwiftUI

/// One of "Your voices" (REQ-ST-20): name, subtitle, In use / Use, play and a "…" menu.
struct VoiceProfileRow: View {
    let profile: VoiceProfileHeader
    let isActive: Bool
    let onUse: () -> Void
    let onPlay: () -> Void
    var onRecordShort: () -> Void = {}
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).lineLimit(1).truncationMode(.tail)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                if isLong { longVoiceHint }
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

    /// REQ-QS-15: a long reference makes the clone answer slower.
    private var isLong: Bool { Double(profile.durationSeconds) > QwenCloneConfiguration.longReferenceSeconds }

    private var longVoiceHint: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "hourglass").font(.caption).foregroundStyle(Theme.Status.orange)
            Text("Long sample: a short recording answers faster")
                .font(.caption).foregroundStyle(.secondary)
            Button("Record short sample", action: onRecordShort)
                .buttonStyle(.link).font(.caption)
        }
    }

    private var subtitle: String {
        let date = profile.createdAt.formatted(date: .abbreviated, time: .omitted)
        let seconds = Int(profile.durationSeconds.rounded())
        return String(localized: "recorded \(date) · \(seconds) s")
    }
}

#Preview("Long voice, light") { VoiceProfileRow.longVoiceFixture().preferredColorScheme(.light) }
#Preview("Long voice, dark") { VoiceProfileRow.longVoiceFixture().preferredColorScheme(.dark) }

extension VoiceProfileRow {
    static func longVoiceFixture(seconds: Float = 48) -> some View {
        let header = VoiceProfileHeader(
            id: UUID(), name: "Santi", createdAt: Date().addingTimeInterval(-6 * 86_400),
            durationSeconds: seconds, sampleRate: 24_000, sampleCount: Int(seconds) * 24_000,
            quality: VoiceQualityMetrics(peakRmsDbfs: -18, hasClipping: false, voicedDurationSeconds: seconds,
                                         grade: .good),
            formatVersion: 1)
        return Form {
            VoiceProfileRow(profile: header, isActive: true, onUse: {}, onPlay: {}, onRename: {}, onDelete: {})
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 120)
    }
}
