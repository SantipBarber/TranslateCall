import SwiftUI

struct StatusBadgeView: View {
    var isCapturing: Bool

    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isCapturing ? Color.green : Color.secondary)
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

            Text(isCapturing ? "Listening" : "Idle")
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
