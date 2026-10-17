import SwiftUI

// MARK: - LegacyEngineChoice

/// Backing value for the legacy engine pickers: automatic or a specific engine.
nonisolated enum LegacyEngineChoice<Engine: Hashable>: Hashable {
    case automatic
    case engine(Engine)

    static func selection(isAutomatic: Bool, preferred: Engine) -> LegacyEngineChoice {
        isAutomatic ? .automatic : .engine(preferred)
    }
}

// MARK: - LegacyAdvancedSettingsView

/// Temporary Advanced (legacy) settings tab that hosts today's technical controls.
struct LegacyAdvancedSettingsView: View {
    @EnvironmentObject private var viewModel: AudioViewModel
    @EnvironmentObject private var setupManager: SetupManager
    @EnvironmentObject private var voiceProfileManager: VoiceProfileManager
    @EnvironmentObject private var sttSelector: STTEngineSelector
    @EnvironmentObject private var ttsSelector: TTSEngineSelector

    @ObservedObject private var vadProvider: VADProvider

    @State private var showVoiceProfiles: Bool = false
    @State private var showSetupWizard: Bool = false

    init(vadProvider: VADProvider) {
        self.vadProvider = vadProvider
    }

    var body: some View {
        Form {
            sttSection
            ttsSection
            diagnosticsSection
            otherSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showVoiceProfiles) { voiceProfilesSheet }
        .sheet(isPresented: $showSetupWizard) { setupWizardSheet }
        .modifier(ModelDownloadSheets())
    }
}

// MARK: - Shared helpers

extension LegacyAdvancedSettingsView {
    /// The usage guide on the repository's main branch (REQ-U-01).
    nonisolated static let guideURL = URL(
        string: "https://github.com/SantipBarber/TranslateCall/blob/main/docs/usage-guide.md"
    )

    /// "VAD: Silero" / "VAD: Energy" / "VAD: —" before the first session.
    nonisolated static func vadLabel(_ engine: VADEngine?) -> String {
        switch engine {
        case .silero: return "VAD: Silero"
        case .energy: return "VAD: Energy"
        case nil: return "VAD: —"
        }
    }
}

// MARK: - Sections

extension LegacyAdvancedSettingsView {
    private var sttSection: some View {
        Section("Speech recognition") {
            Picker("STT Engine", selection: sttBinding) {
                Text("Automatic (recommended)")
                    .tag(LegacyEngineChoice<STTEngine>.automatic)
                Divider()
                ForEach(STTEngine.allCases, id: \.self) { engine in
                    Text(engine.displayName)
                        .tag(LegacyEngineChoice.engine(engine))
                }
            }
            .pickerStyle(.radioGroup)

            HStack(spacing: 8) {
                if sttSelector.isDownloading || sttSelector.isWhisperDownloading {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text(sttSelector.isWhisperDownloading
                         ? "Downloading Whisper model…"
                         : "Downloading Parakeet model…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if sttSelector.usingFallback {
                    Label(sttFallbackLabel, systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
        }
    }

    private var sttFallbackLabel: String {
        switch sttSelector.preferredEngine {
        case .parakeet: return "English only"
        case .whisper: return "Using Apple Speech"
        case .appleSpeech: return ""
        }
    }

    private var ttsSection: some View {
        Section("Voice") {
            Picker("TTS Engine", selection: ttsBinding) {
                Text("Automatic (recommended)")
                    .tag(LegacyEngineChoice<TTSEngine>.automatic)
                Divider()
                ForEach(ttsEngines, id: \.self) { engine in
                    Text(engine.displayName)
                        .tag(LegacyEngineChoice.engine(engine))
                }
            }
            .pickerStyle(.radioGroup)

            HStack(spacing: 8) {
                if ttsSelector.isDownloading {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Downloading Kokoro model…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if ttsSelector.preferredEngine == .kokoro, ttsSelector.kokoroAvailable {
                    KokoroVoicePicker()
                }

                if ttsSelector.isUsingEdgeTTS {
                    Label("Cloud", systemImage: "cloud")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if ttsSelector.usingFallback {
                    Label("English only", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
        }
    }

    private var ttsEngines: [TTSEngine] {
        TTSEngine.allCases.filter { engine in
            engine != .edgeTTS || EdgeTTSConsentManager.consentGiven
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            STTMetricsView()
            TTSMetricsView()
            TTSMonitorRow()
            Text(Self.vadLabel(vadProvider.activeEngine))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var otherSection: some View {
        Section("Other") {
            Button("Voice profiles…") { showVoiceProfiles = true }
            Button("Run setup again…") { showSetupWizard = true }
            if let url = Self.guideURL {
                Link("Usage guide", destination: url)
            }
        }
    }
}

// MARK: - Bindings and sheets

extension LegacyAdvancedSettingsView {
    private var sttBinding: Binding<LegacyEngineChoice<STTEngine>> {
        Binding(
            get: { LegacyEngineChoice.selection(isAutomatic: sttSelector.isAutomatic,
                                                 preferred: sttSelector.preferredEngine) },
            set: { choice in
                if case .automatic = choice {
                    sttSelector.setAutomatic(true)
                } else if case .engine(let engine) = choice {
                    sttSelector.setPreferredEngine(engine)
                }
            }
        )
    }

    private var ttsBinding: Binding<LegacyEngineChoice<TTSEngine>> {
        Binding(
            get: { LegacyEngineChoice.selection(isAutomatic: ttsSelector.isAutomatic,
                                                 preferred: ttsSelector.preferredEngine) },
            set: { choice in
                if case .automatic = choice {
                    ttsSelector.setAutomatic(true)
                } else if case .engine(let engine) = choice {
                    setTTSEngine(engine)
                }
            }
        )
    }

    private func setTTSEngine(_ engine: TTSEngine) {
        ttsSelector.setPreferredEngine(engine)
        if engine == .voiceClone {
            ttsSelector.enableVoiceCloning()
        } else if ttsSelector.voiceCloningEnabled {
            ttsSelector.disableVoiceCloning()
        }
    }

    private var voiceProfilesSheet: some View {
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

    private var setupWizardSheet: some View {
        SetupWizardView(setupManager: setupManager, isPresented: $showSetupWizard)
    }
}

// MARK: - Previews

#Preview("Automatic") {
    let viewModel = AudioViewModel.preview(capturing: false, level: -160)
    LegacyAdvancedSettingsView(vadProvider: viewModel.vadProvider)
        .environmentObject(viewModel)
        .environmentObject(SetupManager())
        .environmentObject(VoiceProfileManager())
        .environmentObject(viewModel.engineSelector)
        .environmentObject(viewModel.ttsEngineSelector)
}

#Preview("Manual") {
    let viewModel = AudioViewModel.preview(capturing: false, level: -160)
    viewModel.engineSelector.setPreferredEngine(.whisper)
    return LegacyAdvancedSettingsView(vadProvider: viewModel.vadProvider)
        .environmentObject(viewModel)
        .environmentObject(SetupManager())
        .environmentObject(VoiceProfileManager())
        .environmentObject(viewModel.engineSelector)
        .environmentObject(viewModel.ttsEngineSelector)
}
