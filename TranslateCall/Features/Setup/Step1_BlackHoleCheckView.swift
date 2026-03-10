import AppKit
import SwiftUI

struct BlackHoleCheckStepView: View {
    @ObservedObject var setupManager: SetupManager

    var body: some View {
        VStack(spacing: 16) {
            // Title
            VStack(spacing: 4) {
                Text("BlackHole Virtual Audio")
                    .font(.headline)
                Text("TranslateCall routes translated speech through BlackHole so your video call app hears it as a microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Status
            if setupManager.isBlackHolePresent {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                    Text("BlackHole 2ch detected")
                        .foregroundStyle(.primary)
                }
                .padding(12)
                .background(Color.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.title2)
                        Text("BlackHole 2ch not found")
                            .foregroundStyle(.primary)
                    }

                    // Install command
                    HStack {
                        Text("brew install blackhole-2ch")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install blackhole-2ch", forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy to clipboard")
                    }
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                    HStack(spacing: 12) {
                        Button("Download Installer") {
                            if let url = URL(string: "https://existential.audio/blackhole/") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)

                        Button("Refresh") {
                            setupManager.checkBlackHole()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Spacer()

            Text("Tip: You can continue to step 2 even without BlackHole — incoming translation will be unavailable until it is installed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Previews

#Preview("BlackHole present") {
    let mgr = SetupManager()
    BlackHoleCheckStepView(setupManager: mgr)
        .padding()
        .frame(width: 430)
}
