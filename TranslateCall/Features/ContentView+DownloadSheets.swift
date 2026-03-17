import SwiftUI

// MARK: - Download Sheets (extracted to reduce ContentView body length)

extension ContentView {
    var parakeetDownloadSheet: some View {
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

    var kokoroDownloadSheet: some View {
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

    var voiceCloneDownloadSheet: some View {
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

    var whisperDownloadSheet: some View {
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
