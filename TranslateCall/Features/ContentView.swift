import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: AudioViewModel

    var body: some View {
        VStack(spacing: 16) {
            DeviceSectionView()

            Divider()

            LanguagePairView()
                .padding(.horizontal, 4)

            HStack {
                StatusBadgeView(
                    isCapturing: viewModel.isCapturing,
                    isSpeechActive: viewModel.isSpeechActive,
                    isTranslating: viewModel.isTranslating,
                    isSpeaking: viewModel.isSpeaking
                )
                Spacer()
                #if DEBUG
                if viewModel.isCapturing {
                    Button("Test TTS") { viewModel.testTTS() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                #endif
            }

            LevelMeterView(level: viewModel.inputLevel, isActive: viewModel.isCapturing)

            TranscriptionView(
                text: viewModel.latestTranscription,
                isTranscribing: viewModel.isTranscribing,
                translatedText: viewModel.latestTranslation,
                isTranslating: viewModel.isTranslating
            )

            CaptureButtonView()
        }
        .padding(24)
        .frame(width: 480, height: 440)
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
    }
}

#Preview("Idle") {
    ContentView()
        .environmentObject(AudioViewModel.preview(capturing: false, level: -160))
}

#Preview("Capturing") {
    ContentView()
        .environmentObject(AudioViewModel.preview(capturing: true, level: -18))
}
