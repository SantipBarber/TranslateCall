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
                    isSpeaking: viewModel.isSpeaking,
                    isIncomingActive: viewModel.isIncomingActive
                )
                Spacer()
            }

            LevelMeterView(level: viewModel.inputLevel, isActive: viewModel.isCapturing)

            TranscriptionView(
                text: viewModel.latestTranscription,
                isTranscribing: false,
                translatedText: viewModel.latestTranslation,
                incomingText: viewModel.incomingTranscription,
                incomingTranslation: viewModel.incomingTranslation,
                isIncomingActive: viewModel.isIncomingActive
            )

            CaptureButtonView()
        }
        .padding(24)
        .frame(width: 480, height: 520)
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
