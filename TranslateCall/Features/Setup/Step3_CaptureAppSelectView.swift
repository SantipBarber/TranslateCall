@preconcurrency import ScreenCaptureKit
import SwiftUI

struct CaptureAppSelectStepView: View {
    @ObservedObject var setupManager: SetupManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title
            VStack(alignment: .leading, spacing: 4) {
                Text("Select Capture Source")
                    .font(.headline)
                Text("Choose which app's audio TranslateCall should capture for incoming translation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if setupManager.isLoadingCaptureApps {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if setupManager.availableCaptureApps.isEmpty {
                VStack(spacing: 8) {
                    Text("No apps found.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Grant Screen Recording Permission") {
                        Task { await setupManager.requestScreenCapturePermission() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        // "None" option
                        appRow(name: "None (outgoing only)", isSelected: setupManager.selectedCaptureApp == nil) {
                            setupManager.selectCaptureApp(nil)
                        }

                        ForEach(setupManager.availableCaptureApps, id: \.processID) { app in
                            appRow(name: app.applicationName, isSelected: setupManager.selectedCaptureApp?.processID == app.processID) {
                                setupManager.selectCaptureApp(app)
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Refresh") {
                    Task { await setupManager.refreshCaptureApps() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    // MARK: - Row helper

    private func appRow(name: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(name)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .font(.caption.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    CaptureAppSelectStepView(setupManager: SetupManager())
        .padding()
        .frame(width: 430, height: 280)
}
