import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: AudioViewModel

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return "v\(version)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "waveform.and.mic")
                    .foregroundStyle(.tint)
                Text("TranslateCall")
                    .font(.headline)
                Spacer()
                Text(versionString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Status
            StatusBadgeView(
                isCapturing: viewModel.isCapturing,
                isSpeechActive: viewModel.isSpeechActive,
                halfDuplexState: viewModel.halfDuplexState,
                isIncomingActive: viewModel.isIncomingActive
            )
            IncomingStatusBanner(status: viewModel.incomingStatus) { viewModel.retryIncoming() }

            // Language pair
            HStack(spacing: 6) {
                Text(viewModel.sourceLanguageDisplay)
                    .font(.subheadline)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(viewModel.targetLanguageDisplay)
                    .font(.subheadline)
                Spacer()
            }

            Divider()

            // Start / Stop
            Button {
                Task { await viewModel.toggleCapture() }
            } label: {
                Label(
                    viewModel.isCapturing ? "Stop Translation" : "Start Translation",
                    systemImage: viewModel.isCapturing ? "stop.fill" : "mic.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isCapturing ? .red : .accentColor)
            .controlSize(.large)
            .keyboardShortcut("t", modifiers: [.command, .shift])

            // Open main window
            Button("Open Main Window") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(.tint)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .frame(width: 280)
    }
}

// MARK: - Preview

#Preview {
    MenuBarPopoverView(viewModel: AudioViewModel.preview())
}
