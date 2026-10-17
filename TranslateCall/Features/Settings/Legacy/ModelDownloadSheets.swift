import SwiftUI

// MARK: - ModelDownloadSheets

/// Sheets shown while Parakeet, Kokoro, Voice Clone or Whisper models download.
struct ModelDownloadSheets: ViewModifier {
    @EnvironmentObject private var viewModel: AudioViewModel
    @EnvironmentObject private var ttsSelector: TTSEngineSelector

    @State private var showParakeetDownload: Bool = false
    @State private var showKokoroDownload: Bool = false
    @State private var showVoiceCloneDownload: Bool = false
    @State private var showWhisperDownload: Bool = false
    @State private var whisperModelSize: WhisperModelSize = .base

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showParakeetDownload) { parakeetDownloadSheet }
            .sheet(isPresented: $showKokoroDownload) { kokoroDownloadSheet }
            .sheet(isPresented: $showVoiceCloneDownload) { voiceCloneDownloadSheet }
            .sheet(isPresented: $showWhisperDownload) { whisperDownloadSheet }
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
    }

    // MARK: - Sheets

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
                ttsSelector.setPreferredEngine(.avSpeech)
                ttsSelector.unloadKokoroModel()
                showKokoroDownload = false
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(width: 280)
    }

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
                ttsSelector.disableVoiceCloning()
                showVoiceCloneDownload = false
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(width: 280)
    }

    private var whisperDownloadSheet: some View {
        VStack(spacing: 16) {
            Text("Download Whisper Model")
                .font(.headline)
            Text("Select model size (larger = better quality, slower).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Model", selection: $whisperModelSize) {
                ForEach(WhisperModelSize.allCases, id: \.self) { size in
                    Text("\(size.displayName) (~\(size.approximateSizeMB) MB)")
                        .tag(size)
                }
            }
            .pickerStyle(.radioGroup)

            Text(whisperModelSize.qualityDescription)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            ProgressView()
                .scaleEffect(1.2)

            Button("Cancel") {
                viewModel.engineSelector.setPreferredEngine(.appleSpeech)
                showWhisperDownload = false
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(width: 320)
    }
}
