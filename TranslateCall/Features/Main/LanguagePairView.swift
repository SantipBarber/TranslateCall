import SwiftUI

struct LanguagePairView: View {
    @EnvironmentObject private var viewModel: AudioViewModel

    private var manager: LanguagePairManager { viewModel.languagePairManager }
    private var selector: STTEngineSelector { viewModel.engineSelector }
    private var ttsSelector: TTSEngineSelector { viewModel.ttsEngineSelector }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Language pair row
            HStack(spacing: 8) {
                languagePicker(
                    selection: manager.sourceLanguage,
                    onChange: { lang in Task { await manager.setSourceLanguage(lang) } }
                )

                Button {
                    Task { await manager.swapLanguages() }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.plain)
                .help("Swap languages")

                languagePicker(
                    selection: manager.targetLanguage,
                    onChange: { lang in Task { await manager.setTargetLanguage(lang) } }
                )

                pairStatusIndicator

                if manager.pairStatus == .supported {
                    Button("Download") {
                        Task { await viewModel.downloadLanguages() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // STT engine selector row
            engineSelectorRow

            // TTS engine selector row
            ttsEngineSelectorRow
        }
        .disabled(viewModel.isCapturing)
    }

    // MARK: - STT engine row

    private var engineSelectorRow: some View {
        HStack(spacing: 6) {
            Text("STT")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            Picker("STT Engine", selection: Binding(
                get: { selector.preferredEngine },
                set: { selector.setPreferredEngine($0) }
            )) {
                ForEach(STTEngine.allCases, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .help(enginePickerHelp)

            if selector.isDownloading || selector.isWhisperDownloading {
                ProgressView()
                    .scaleEffect(0.6)
                    .help(selector.isWhisperDownloading
                        ? "Downloading Whisper model…"
                        : "Downloading Parakeet model…")
            }

            if selector.usingFallback {
                Label(
                    fallbackLabel,
                    systemImage: "info.circle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
            }
        }
    }

    // MARK: - TTS engine row

    @AppStorage(KokoroConfiguration.voiceDefaultsKey) private var kokoroVoice: String = ""

    private static let kokoroVoices: [(id: String, label: String)] = [
        ("", "Default (af_heart)"),
        ("af_heart", "af_heart"),
        ("af_bella", "af_bella"),
        ("am_adam", "am_adam"),
        ("am_michael", "am_michael")
    ]

    private var ttsEngineSelectorRow: some View {
        HStack(spacing: 6) {
            Text("TTS")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            Picker("TTS Engine", selection: Binding(
                get: { ttsSelector.preferredEngine },
                set: { engine in
                    ttsSelector.setPreferredEngine(engine)
                    if engine == .voiceClone {
                        ttsSelector.enableVoiceCloning()
                    } else if ttsSelector.voiceCloningEnabled {
                        ttsSelector.disableVoiceCloning()
                    }
                }
            )) {
                ForEach(TTSEngine.allCases, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .help(ttsEnginePickerHelp)

            if ttsSelector.isDownloading {
                ProgressView()
                    .scaleEffect(0.6)
                    .help("Downloading Kokoro model…")
            }

            if ttsSelector.preferredEngine == .kokoro, ttsSelector.kokoroAvailable {
                Picker("Voice", selection: $kokoroVoice) {
                    ForEach(Self.kokoroVoices, id: \.id) { voice in
                        Text(voice.label).tag(voice.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 140)
                .help("Kokoro voice variant")
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

    private var ttsEnginePickerHelp: String {
        if !ttsSelector.kokoroAvailable && ttsSelector.preferredEngine == .kokoro {
            return "Kokoro model not yet downloaded. Select to begin download."
        }
        return "AVSpeech supports all languages. Kokoro provides higher quality for English (on-device)."
    }

    // MARK: - STT engine picker help

    private var fallbackLabel: String {
        switch selector.preferredEngine {
        case .parakeet: return "English only"
        case .whisper:  return "Using Apple Speech"
        case .appleSpeech: return ""
        }
    }

    private var enginePickerHelp: String {
        switch selector.preferredEngine {
        case .parakeet where !selector.parakeetAvailable:
            return "Parakeet model not yet downloaded."
        case .whisper where !selector.whisperAvailable:
            return "Whisper model not yet downloaded."
        default:
            return "Apple Speech: all languages. Parakeet: English. Whisper: 99+ languages (on-device)."
        }
    }

    // MARK: - Language pair subviews

    private var pairStatusIndicator: some View {
        Group {
            switch manager.pairStatus {
            case .installed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .supported:
                Image(systemName: "arrow.down.circle").foregroundStyle(.orange)
            case .unsupported:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .unknown:
                ProgressView().scaleEffect(0.6)
            }
        }
        .help(pairStatusHelp)
    }

    private var pairStatusHelp: String {
        switch manager.pairStatus {
        case .installed:   return "Language models installed"
        case .supported:   return "Models need to be downloaded"
        case .unsupported: return "Language pair not supported"
        case .unknown:     return "Checking availability…"
        }
    }

    private func languagePicker(
        selection: Locale.Language,
        onChange: @escaping (Locale.Language) -> Void
    ) -> some View {
        Picker("", selection: Binding(
            get: { selection },
            set: { onChange($0) }
        )) {
            ForEach(manager.supportedLanguages, id: \.minimalIdentifier) { lang in
                Text(manager.displayName(for: lang)).tag(lang)
            }
        }
        .frame(width: 120)
    }
}
