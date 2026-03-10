@preconcurrency import ScreenCaptureKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: AudioViewModel
    @EnvironmentObject private var setupManager: SetupManager

    @State private var showSetupWizard: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 16) {
            DeviceSectionView()

            Divider()

            LanguagePairView()
                .padding(.horizontal, 4)

            // BlackHole warning banner (conditional)
            if !setupManager.isBlackHolePresent {
                SetupBannerView { showSetupWizard = true }
            }

            HStack {
                StatusBadgeView(
                    isCapturing: viewModel.isCapturing,
                    isSpeechActive: viewModel.isSpeechActive,
                    halfDuplexState: viewModel.halfDuplexState,
                    isIncomingActive: viewModel.isIncomingActive
                )
                Spacer()
                Button("Setup…") { showSetupWizard = true }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LevelMeterView(level: viewModel.inputLevel, isActive: viewModel.isCapturing)

            // Capture app selector (compact, single row)
            captureAppRow

            TranscriptionView(
                text: viewModel.latestTranscription,
                isTranscribing: false,
                translatedText: viewModel.latestTranslation,
                incomingText: viewModel.incomingTranscription,
                incomingTranslation: viewModel.incomingTranslation,
                isIncomingActive: viewModel.isIncomingActive
            )

            HStack(spacing: 12) {
                CaptureButtonView()
                Button("Mute Turn") { viewModel.muteTurn() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(!viewModel.isCapturing)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 480, height: 560)
        .alert(item: $viewModel.errorAlert) { (alert: AlertItem) in
            if alert.action == .openSettings {
                let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Open Settings")) {
                        if let url = URL(string: settingsURL) { NSWorkspace.shared.open(url) }
                    },
                    secondaryButton: .cancel()
                )
            }
            return Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .sheet(isPresented: $showSetupWizard) {
            SetupWizardView(setupManager: setupManager, isPresented: $showSetupWizard)
        }
        .onAppear {
            setupManager.checkBlackHole()
            if !setupManager.isSetupCompleted {
                showSetupWizard = true
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                setupManager.checkBlackHole()
            }
        }
    }

    // MARK: - Capture app row

    private var captureAppRow: some View {
        HStack(spacing: 8) {
            Text("Capture:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("", selection: captureAppBinding) {
                Text("None").tag(Optional<SCRunningApplication>.none)
                ForEach(setupManager.availableCaptureApps, id: \.processID) { app in
                    Text(app.applicationName).tag(Optional(app))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)

            Spacer()
        }
    }

    private var captureAppBinding: Binding<SCRunningApplication?> {
        Binding(
            get: { setupManager.selectedCaptureApp },
            set: { setupManager.selectCaptureApp($0) }
        )
    }
}

#Preview("Idle") {
    ContentView()
        .environmentObject(AudioViewModel.preview(capturing: false, level: -160))
        .environmentObject(SetupManager())
}

#Preview("Capturing") {
    ContentView()
        .environmentObject(AudioViewModel.preview(capturing: true, level: -18))
        .environmentObject(SetupManager())
}
