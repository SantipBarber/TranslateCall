@preconcurrency import ScreenCaptureKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: AudioViewModel
    @EnvironmentObject private var setupManager: SetupManager
    @EnvironmentObject private var voiceProfileManager: VoiceProfileManager
    @EnvironmentObject private var ttsSelector: TTSEngineSelector

    @State private var showSetupWizard: Bool = false
    @State private var showVoiceProfiles: Bool = false
    @State var showParakeetDownload: Bool = false
    @State var showKokoroDownload: Bool = false
    @State var showVoiceCloneDownload: Bool = false
    @State var showWhisperDownload: Bool = false
    @State var whisperModelSize: WhisperModelSize = .base
    // Edge TTS consent is driven by viewModel.showEdgeTTSConsent
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
                    conversationState: viewModel.conversationState,
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

            IncomingStatusBanner(status: viewModel.incomingStatus) { viewModel.retryIncoming() }
            TranscriptionView(
                text: viewModel.latestTranscription,
                isTranscribing: false,
                translatedText: viewModel.latestTranslation,
                incomingText: viewModel.incomingTranscription,
                incomingTranslation: viewModel.incomingTranslation,
                isIncomingActive: viewModel.isIncomingActive
            )
            TTSNoticeLine(text: viewModel.ttsNotice)

            STTMetricsView()
                .padding(.horizontal, 2)

            TTSMetricsView()
                .padding(.horizontal, 2)

            // TTS Monitor row (local playback + recording)
            ttsMonitorRow

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
                VoiceProfileListView(isSessionActive: viewModel.isSessionActive)
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
        .sheet(isPresented: $showWhisperDownload) {
            whisperDownloadSheet
        }
        .onChange(of: viewModel.engineSelector.isDownloading) { _, downloading in
            showParakeetDownload = downloading
        }
        .onChange(of: viewModel.engineSelector.isWhisperDownloading) { _, downloading in
            if downloading { showWhisperDownload = true }
        }
        .onChange(of: ttsSelector.isDownloading) { _, downloading in
            showKokoroDownload = downloading
        }
        .onChange(of: ttsSelector.isVoiceCloneDownloading) { _, downloading in
            showVoiceCloneDownload = downloading
        }
        .alert(
            "Cloud TTS Required",
            isPresented: $viewModel.showEdgeTTSConsent
        ) {
            Button("Enable") {
                viewModel.onEdgeTTSConsentResponse(accepted: true)
            }
            Button("Not Now", role: .cancel) {
                viewModel.onEdgeTTSConsentResponse(accepted: false)
            }
        } message: {
            Text(
                "No voice is available for this language on your device. "
                + "Enable Cloud TTS? Text will be sent to Microsoft for speech synthesis."
            )
        }
        // Force re-render when nested ObservableObject properties change
        .onChange(of: ttsSelector.voiceCloneAvailable) { _, _ in }
        .onChange(of: ttsSelector.voiceCloningEnabled) { _, _ in }
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

    // MARK: - TTS Monitor row

    private var ttsMonitorRow: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { viewModel.ttsMonitorEnabled },
                set: { _ in viewModel.toggleTTSMonitor() }
            )) {
                Label("Monitor", systemImage: viewModel.ttsMonitorEnabled
                      ? "speaker.wave.2.fill" : "speaker.slash")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Spacer()

            if viewModel.ttsMonitorEnabled {
                Button {
                    viewModel.toggleTTSRecording()
                } label: {
                    Image(systemName: viewModel.ttsMonitorRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(viewModel.ttsMonitorRecording ? .red : .secondary)
                }
                .buttonStyle(.borderless)
                .help(viewModel.ttsMonitorRecording ? "Stop recording" : "Record TTS output")

                if viewModel.hasRecording, !viewModel.ttsMonitorRecording {
                    Button {
                        viewModel.playLastRecording()
                    } label: {
                        Image(systemName: "play.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Play last recording")
                }
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
