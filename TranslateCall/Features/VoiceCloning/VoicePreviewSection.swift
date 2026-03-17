import SwiftUI

// MARK: - VoicePreviewSection

/// Preview controls for voice cloning: clone preview, A/B compare, training playback.
struct VoicePreviewSection: View {
    let profileId: UUID
    let previewService: VoicePreviewService
    let isSessionActive: Bool

    @State private var previewState: VoicePreviewService.PreviewState = .idle
    @State private var selectedLanguage: String = "english"
    @State private var customText: String = ""

    private var demoText: String {
        customText.isEmpty
            ? QwenCloneConfiguration.demoText(for: selectedLanguage)
            : customText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview")
                .font(.subheadline.bold())

            // Language picker
            HStack(spacing: 8) {
                Text("Language")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $selectedLanguage) {
                    ForEach(QwenCloneConfiguration.supportedLanguageList, id: \.key) { lang in
                        Text(lang.label).tag(lang.key)
                    }
                }
                .frame(maxWidth: 140)
                Spacer()
            }

            // Demo text (editable)
            TextField(
                "Demo text",
                text: $customText,
                prompt: Text(QwenCloneConfiguration.demoText(for: selectedLanguage))
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)

            // Action buttons
            HStack(spacing: 10) {
                // Preview cloned voice
                Button {
                    Task {
                        await previewService.previewClone(
                            profileId: profileId,
                            text: demoText,
                            language: selectedLanguage
                        )
                    }
                } label: {
                    Label("Preview", systemImage: previewButtonIcon)
                }
                .disabled(!canPreview)

                // A/B Comparison
                Button {
                    let locale = localeForLanguage(selectedLanguage)
                    Task {
                        await previewService.compareAB(
                            profileId: profileId,
                            text: demoText,
                            locale: locale
                        )
                    }
                } label: {
                    Label("Compare", systemImage: "arrow.left.arrow.right")
                }
                .disabled(!canPreview)

                // Stop
                Button {
                    Task { await previewService.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!isPlaying)

                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            // Play recording (no model needed)
            Button {
                Task { await previewService.playRecording(profileId: profileId) }
            } label: {
                Label("Play Recording", systemImage: recordingButtonIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isPlaying)

            // Status label
            statusLabel
        }
        .task {
            for await newState in previewService.stateStream {
                previewState = newState
            }
        }
        .onDisappear {
            Task { await previewService.stop() }
        }
    }

    // MARK: - Computed state

    private var isPlaying: Bool {
        switch previewState {
        case .synthesizing, .playing, .loadingModel: return true
        default: return false
        }
    }

    private var canPreview: Bool {
        !isPlaying && !isSessionActive
    }

    private var previewButtonIcon: String {
        if case .synthesizing(.cloned) = previewState { return "ellipsis" }
        if case .loadingModel = previewState { return "ellipsis" }
        return "play.fill"
    }

    private var recordingButtonIcon: String {
        if case .playing(.recording) = previewState { return "stop.fill" }
        return "play.fill"
    }

    // MARK: - Status label

    @ViewBuilder
    private var statusLabel: some View {
        switch previewState {
        case .idle:
            EmptyView()
        case .loadingModel:
            Label("Loading model...", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .synthesizing(let mode):
            Label("Synthesizing \(modeName(mode))...", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.blue)
        case .playing(let mode):
            Label("Playing \(modeName(mode))", systemImage: "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func modeName(_ mode: VoicePreviewService.VoicePreviewMode) -> String {
        switch mode {
        case .cloned: return "cloned voice"
        case .standard: return "standard voice"
        case .abComparison: return "comparison"
        case .recording: return "recording"
        }
    }

    // MARK: - Helpers

    private static let languageLocaleMap: [String: String] = [
        "english": "en-US",
        "spanish": "es-ES",
        "french": "fr-FR",
        "german": "de-DE",
        "italian": "it-IT",
        "portuguese": "pt-BR",
        "russian": "ru-RU",
        "chinese": "zh-CN",
        "japanese": "ja-JP",
        "korean": "ko-KR"
    ]

    private func localeForLanguage(_ language: String) -> Locale {
        Locale(identifier: Self.languageLocaleMap[language] ?? "en-US")
    }
}
