import SwiftUI

struct StatusBadgeView: View {
    var isCapturing: Bool
    var isSpeechActive: Bool = false
    var halfDuplexState: HalfDuplexState = .listening
    var isIncomingActive: Bool = false

    @State private var isPulsing = false

    private var badgeColor: Color {
        guard isCapturing else { return .secondary }
        switch halfDuplexState {
        case .listening:    return isSpeechActive ? .orange : .green
        case .speaking:     return .red
        case .transitioning: return .yellow
        }
    }

    private var label: String {
        guard isCapturing else { return "Idle" }
        switch halfDuplexState {
        case .listening:    return isSpeechActive ? "Speech detected" : "Listening"
        case .speaking:     return "Speaking"
        case .transitioning: return "Transitioning…"
        }
    }

    private var micIcon: String {
        switch halfDuplexState {
        case .listening:    return "mic"
        case .speaking:     return "mic.slash"
        case .transitioning: return "clock"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 10, height: 10)
                .scaleEffect(isPulsing ? 1.3 : 1.0)
                .animation(
                    isCapturing
                        ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                        : .default,
                    value: isPulsing
                )
                .onChange(of: isCapturing) { _, capturing in
                    isPulsing = capturing
                }
                .onAppear {
                    isPulsing = isCapturing
                }

            Image(systemName: micIcon)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .animation(.default, value: label)

            if isIncomingActive {
                Image(systemName: "headphones")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Idle") {
    StatusBadgeView(isCapturing: false)
        .padding()
}

#Preview("Listening") {
    StatusBadgeView(isCapturing: true)
        .padding()
}

#Preview("Speech Active") {
    StatusBadgeView(isCapturing: true, isSpeechActive: true)
        .padding()
}

#Preview("Speaking (half-duplex)") {
    StatusBadgeView(isCapturing: true, halfDuplexState: .speaking, isIncomingActive: true)
        .padding()
}

#Preview("Transitioning") {
    StatusBadgeView(isCapturing: true, halfDuplexState: .transitioning)
        .padding()
}
