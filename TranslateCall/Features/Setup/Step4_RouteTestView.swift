import SwiftUI

struct RouteTestStepView: View {
    @ObservedObject var setupManager: SetupManager
    @ObservedObject var routeTestService: RouteTestService

    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 20) {
            // Title
            VStack(spacing: 4) {
                Text("Test Audio Routing")
                    .font(.headline)
                Text("Play a test tone through BlackHole to confirm your video call app receives TranslateCall audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // State-dependent content
            Group {
                switch routeTestService.state {
                case .idle:
                    idleView

                case .playing:
                    playingView

                case .succeeded:
                    succeededView

                case .failed(let message):
                    failedView(message: message)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer()
        }
    }

    // MARK: - State views

    private var idleView: some View {
        VStack(spacing: 12) {
            if setupManager.isBlackHolePresent {
                Text("Click Play to send a test tone to BlackHole 2ch.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Play Test") {
                    Task {
                        await routeTestService.run(
                            blackHoleDeviceID: AudioDevice.deviceID(forNameContaining: "BlackHole")
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("BlackHole not detected — skipping audio test.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var playingView: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 60, height: 60)
                    .scaleEffect(isPulsing ? 1.4 : 1.0)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: isPulsing)
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .onAppear { isPulsing = true }
            .onDisappear { isPulsing = false }

            Text("Playing test tone…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var succeededView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)

            Text("Audio sent to BlackHole 2ch")
                .font(.subheadline.weight(.semibold))

            Text("If you saw audio activity in your video call app, setup is complete!")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Run Again") {
                routeTestService.reset()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.red)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Retry") {
                Task {
                    await routeTestService.run(
                        blackHoleDeviceID: AudioDevice.deviceID(forNameContaining: "BlackHole")
                    )
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Preview

#Preview("Idle") {
    RouteTestStepView(setupManager: SetupManager(), routeTestService: RouteTestService())
        .padding()
        .frame(width: 430, height: 260)
}
