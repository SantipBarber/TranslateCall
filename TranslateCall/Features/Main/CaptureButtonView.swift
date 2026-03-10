import SwiftUI

struct CaptureButtonView: View {
    @EnvironmentObject private var viewModel: AudioViewModel

    var body: some View {
        Button {
            Task { await viewModel.toggleCapture() }
        } label: {
            Label(
                viewModel.isCapturing ? "Stop" : "Start",
                systemImage: viewModel.isCapturing ? "stop.fill" : "mic.fill"
            )
            .frame(minWidth: 100)
        }
        .buttonStyle(.borderedProminent)
        .tint(viewModel.isCapturing ? .red : .accentColor)
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(
            viewModel.isStarting ||
            (!viewModel.isCapturing && viewModel.languagePairManager.pairStatus == .unsupported)
        )
    }
}

#Preview("Idle") {
    CaptureButtonView()
        .environmentObject(AudioViewModel.preview(capturing: false))
        .padding()
}

#Preview("Capturing") {
    CaptureButtonView()
        .environmentObject(AudioViewModel.preview(capturing: true))
        .padding()
}
