import AppKit
import SwiftUI

/// A tinted card with a title and a wrapping body (REQ-UI-31/32/32a). Copy comes from `Readiness.Card`.
private struct StateCardBox<Footer: View>: View {
    let card: Readiness.Card
    let tint: Color
    let systemImage: String
    @ViewBuilder let footer: Footer

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: systemImage).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title).fontWeight(.semibold)
                Text(card.message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                footer
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.medium)
        .background(Theme.soft(tint))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            .stroke(tint.opacity(0.4), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}

/// Microphone or Screen Recording is off (red).
struct PermissionCard: View {
    let card: Readiness.Card

    var body: some View {
        StateCardBox(card: card, tint: Theme.Status.red, systemImage: "exclamationmark.triangle.fill") {
            Button { NSWorkspace.shared.open(settingsURL) } label: {
                Text("Open System Settings").fontWeight(.medium).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private var settingsURL: URL {
        card == .screenRecordingOff ? PermissionState.screenRecordingSettingsURL
                                    : PermissionState.microphoneSettingsURL
    }
}

struct CallAppNotOpenCard: View {
    let card: Readiness.Card

    var body: some View {
        StateCardBox(card: card, tint: Theme.Status.orange, systemImage: "exclamationmark.circle.fill") {
            EmptyView()
        }
    }
}

struct AudioDriverCard: View {
    let card: Readiness.Card
    let onSetUp: () -> Void

    var body: some View {
        StateCardBox(card: card, tint: Theme.Status.orange, systemImage: "speaker.slash.fill") {
            Button("Set up…", action: onSetUp).buttonStyle(.bordered).controlSize(.small)
        }
    }
}

#if DEBUG
struct StateCardsPreviewContent: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            PermissionCard(card: .microphoneOff)
            PermissionCard(card: .screenRecordingOff)
            CallAppNotOpenCard(card: .callAppNotOpen("Microsoft Teams (work or school)"))
            AudioDriverCard(card: .audioDriverMissing, onSetUp: {})
        }
        .padding()
        .frame(width: 360)
        .background(Color(.windowBackgroundColor))
    }
}

#Preview("Cards — light") { StateCardsPreviewContent() }
#Preview("Cards — dark") { StateCardsPreviewContent().preferredColorScheme(.dark) }
#endif
