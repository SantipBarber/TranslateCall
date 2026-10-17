import SwiftUI

// MARK: - TTSMonitorRow

/// Local playback + recording controls for the TTS monitor.
struct TTSMonitorRow: View {
    @EnvironmentObject private var viewModel: AudioViewModel

    var body: some View {
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
}

#Preview {
    TTSMonitorRow()
        .environmentObject(AudioViewModel.preview(capturing: false, level: -160))
        .padding()
}
