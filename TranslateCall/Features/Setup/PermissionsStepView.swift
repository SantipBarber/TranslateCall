import SwiftUI

/// Step 1: Microphone and Screen & System Audio Recording (REQ-FR-10…13).
struct PermissionsStepView: View {
    let permissions: PermissionState
    /// True once screen recording was requested: the grant only shows after a relaunch (REQ-FR-12).
    let canReopen: Bool
    let onAllowMicrophone: () -> Void
    let onAllowScreenRecording: () -> Void
    let onReopen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SetupStepHeader(
                title: String(localized: "Allow TranslateCall to hear the call"),
                subtitle: String(localized: """
                    macOS asks for two permissions. TranslateCall only listens while you're translating, \
                    and nothing is recorded or sent anywhere.
                    """))
            CardBox {
                VStack(spacing: 0) {
                    PermissionRow(symbol: "mic.fill", title: String(localized: "Microphone"),
                                  detail: String(localized: "To hear what you say and translate it for them."),
                                  status: permissions.microphone, onAllow: onAllowMicrophone)
                    Divider()
                    PermissionRow(symbol: "rectangle.on.rectangle",
                                  title: String(localized: "Screen & System Audio Recording"),
                                  detail: String(localized: """
                                      To hear the other person through your call app. No video is captured.
                                      """),
                                  status: permissions.screenRecording, onAllow: onAllowScreenRecording)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("After you allow Screen & System Audio Recording, macOS may ask you to reopen TranslateCall.",
                      systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if canReopen, permissions.screenRecording != .granted {
                    Button("Reopen TranslateCall", action: onReopen).controlSize(.regular)
                }
            }
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let status: PermissionStatus
    let onAllow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.soft(Theme.accent), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailing: some View {
        if status == .granted {
            Label("Allowed", systemImage: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Status.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.soft(Theme.Status.green), in: Capsule())
        } else {
            Button("Allow…", action: onAllow)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Allow \(title)")
        }
    }
}
