import SwiftUI

struct StatusBadgeView: View {
    var isCapturing: Bool
    var isSpeechActive: Bool = false
    var conversationState: ConversationState = .listening
    var isIncomingActive: Bool = false

    @State private var isPulsing = false

    /// Label and mic icon for a state (F8.5.3 REQ-H-13). Nothing is muted while a translation
    /// plays, except the mic in speakers mode (`.micPaused`).
    nonisolated static func presentation(isCapturing: Bool, isSpeechActive: Bool,
                                         state: ConversationState) -> (label: String, icon: String) {
        guard isCapturing else { return ("Idle", "mic") }
        switch state {
        case .listening:  return (isSpeechActive ? "Speech detected" : "Listening", "mic")
        case .speaking:   return ("Speaking translation", "speaker.wave.2")
        case .micPaused:  return ("Mic paused (speakers)", "mic.slash")
        }
    }

    private var badgeColor: Color {
        guard isCapturing else { return .secondary }
        switch conversationState {
        case .listening:  return isSpeechActive ? .orange : .green
        case .speaking:   return .blue
        case .micPaused:  return .yellow
        }
    }

    private var label: String {
        Self.presentation(isCapturing: isCapturing, isSpeechActive: isSpeechActive, state: conversationState).label
    }

    private var micIcon: String {
        Self.presentation(isCapturing: isCapturing, isSpeechActive: isSpeechActive, state: conversationState).icon
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

#Preview("Speaking translation") {
    StatusBadgeView(isCapturing: true, conversationState: .speaking, isIncomingActive: true)
        .padding()
}

#Preview("Mic paused (speakers)") {
    StatusBadgeView(isCapturing: true, conversationState: .micPaused, isIncomingActive: true)
        .padding()
}
