@preconcurrency import ScreenCaptureKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: AudioViewModel
    @EnvironmentObject private var setupManager: SetupManager

    @EnvironmentObject private var voiceProfileManager: VoiceProfileManager

    @State private var showSetupWizard: Bool = false
    @State private var showVoiceProfiles: Bool = false
    @State private var showParakeetDownload: Bool = false
    @State private var showKokoroDownload: Bool = false
    @State private var showVoiceCloneDownload: Bool = false
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

            STTMetricsView()
                .padding(.horizontal, 2)

            TTSMetricsView()
                .padding(.horizontal, 2)

            // Voice profile row
            voiceProfileRow

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
        .frame(width: 480, height: 680)
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
        .sheet(isPresented: $showVoiceProfiles) {
            NavigationStack {
                VoiceProfileListView()
                    .environmentObject(voiceProfileManager)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showVoiceProfiles = false }
                        }
                    }
            }
            .frame(minWidth: 440, minHeight: 400)
        }
        .sheet(isPresented: $showParakeetDownload) {
            parakeetDownloadSheet
        }
        .sheet(isPresented: $showKokoroDownload) {
            kokoroDownloadSheet
        }
        .sheet(isPresented: $showVoiceCloneDownload) {
            voiceCloneDownloadSheet
        }
        .onChange(of: viewModel.engineSelector.isDownloading) { _, downloading in
            showParakeetDownload = downloading
        }
        .onChange(of: viewModel.ttsEngineSelector.isDownloading) { _, downloading in
            showKokoroDownload = downloading
        }
        .onChange(of: viewModel.ttsEngineSelector.isVoiceCloneDownloading) { _, downloading in
            showVoiceCloneDownload = downloading
        }
        // Force re-render when voice clone availability changes (nested ObservableObject)
        .onChange(of: viewModel.ttsEngineSelector.voiceCloneAvailable) { _, _ in }
        .onChange(of: viewModel.ttsEngineSelector.voiceCloningEnabled) { _, _ in }
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

    // MARK: - Voice profile row

    private var voiceProfileRow: some View {
        HStack(spacing: 8) {
            if let activeProfile = voiceProfileManager.activeProfile {
                Image(systemName: "person.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(activeProfile.name)
                    .font(.caption)
                    .lineLimit(1)
                if viewModel.ttsEngineSelector.voiceCloningActive {
                    Text("Cloning ON")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                } else if viewModel.ttsEngineSelector.voiceCloningEnabled,
                          !QwenCloneConfiguration.supportsLocale(
                              viewModel.ttsEngineSelector.currentTargetLocale
                          ) {
                    Text("Fallback")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
            } else {
                Image(systemName: "person.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("No voice profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Voice Profiles…") { showVoiceProfiles = true }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    // MARK: - Parakeet download sheet

    private var parakeetDownloadSheet: some View {
        VStack(spacing: 16) {
            Text("Downloading Parakeet Model")
                .font(.headline)
            Text("≈ 800 MB · One-time download\nAll transcription runs on-device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView()
                .scaleEffect(1.2)
            Button("Cancel") {
                viewModel.engineSelector.setPreferredEngine(.appleSpeech)
                viewModel.engineSelector.unloadParakeetModel()
                showParakeetDownload = false
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(width: 280)
    }

    // MARK: - Kokoro download sheet

    private var kokoroDownloadSheet: some View {
        VStack(spacing: 16) {
            Text("Downloading Kokoro Model")
                .font(.headline)
            Text("≈ 300 MB · One-time download\nAll synthesis runs on-device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView()
                .scaleEffect(1.2)
            Button("Cancel") {
                viewModel.ttsEngineSelector.setPreferredEngine(.avSpeech)
                viewModel.ttsEngineSelector.unloadKokoroModel()
                showKokoroDownload = false
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(width: 280)
    }

    // MARK: - Voice Clone download sheet

    private var voiceCloneDownloadSheet: some View {
        VStack(spacing: 16) {
            Text("Downloading Voice Clone Model")
                .font(.headline)
            Text("~2 GB · one-time download\nAll synthesis runs on-device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView()
                .scaleEffect(1.2)
            Button("Cancel") {
                viewModel.ttsEngineSelector.disableVoiceCloning()
                showVoiceCloneDownload = false
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(width: 280)
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
        .environmentObject(VoiceProfileManager())
}

#Preview("Capturing") {
    ContentView()
        .environmentObject(AudioViewModel.preview(capturing: true, level: -18))
        .environmentObject(SetupManager())
        .environmentObject(VoiceProfileManager())
}
