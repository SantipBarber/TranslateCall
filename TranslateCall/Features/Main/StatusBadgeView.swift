import SwiftUI

struct StatusBadgeView: View {
    var isCapturing: Bool
    var isSpeechActive: Bool = false
    var isTranslating: Bool = false
    var isSpeaking: Bool = false

    @State private var isPulsing = false

    private var badgeColor: Color {
        if isSpeaking { return .red }
        if isTranslating { return .blue }
        if isSpeechActive { return .orange }
        if isCapturing { return .green }
        return .secondary
    }

    private var label: String {
        if isSpeaking { return "Speaking" }
        if isTranslating { return "Translating" }
        if isSpeechActive { return "Speech detected" }
        if isCapturing { return "Listening" }
        return "Idle"
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

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
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

#Preview("Translating") {
    StatusBadgeView(isCapturing: true, isTranslating: true)
        .padding()
}

#Preview("Speaking") {
    StatusBadgeView(isCapturing: true, isSpeaking: true)
        .padding()
}
