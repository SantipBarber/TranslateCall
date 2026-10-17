import SwiftUI

/// "Use my voice": the cloning toggle, the active profile line and the one-time model download
/// (REQ-UI-50…).
struct VoiceSection: View {
    @ObservedObject var ttsSelector: TTSEngineSelector
    let profile: VoiceProfileHeader?
    let targetLocale: Locale
    let targetName: String
    let onOpenProfiles: () -> Void

    private var supported: Bool { QwenCloneConfiguration.supportsLocale(targetLocale) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader("Voice")
            CardBox {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if !supported {
                        detail { Text("Your voice isn't available in \(targetName) yet") }
                    } else if ttsSelector.isVoiceCloneDownloading {
                        detail {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Downloading your voice model… (one time)")
                            }
                        }
                    }
                    if let profile { profileLine(profile) }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "waveform").foregroundStyle(Theme.Status.purple)
                .frame(width: 32, height: 32)
                .background(Theme.soft(Theme.Status.purple))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Use my voice").fontWeight(.medium)
                Text("They hear the translation in your own voice")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.small)
            Toggle("Use my voice", isOn: toggleBinding).labelsHidden().toggleStyle(.switch)
                .disabled(!supported)
        }
        .padding(Theme.Spacing.medium)
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { ttsSelector.voiceCloningEnabled },
            set: { enable in
                if !enable {
                    ttsSelector.disableVoiceCloning()
                } else if profile == nil {
                    onOpenProfiles()
                } else {
                    ttsSelector.enableVoiceCloning()
                }
            }
        )
    }

    private func detail<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Divider()
            content().font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.medium).padding(.vertical, Theme.Spacing.small)
        }
    }

    private func profileLine(_ profile: VoiceProfileHeader) -> some View {
        let date = profile.createdAt.formatted(.dateTime.month(.abbreviated).day())
        return VStack(spacing: 0) {
            Divider()
            HStack {
                Text("Voice: \(profile.name) · recorded \(date)")
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: Theme.Spacing.small)
                Button("Record again", action: onOpenProfiles).buttonStyle(.link)
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.medium).padding(.vertical, Theme.Spacing.small)
        }
    }
}
