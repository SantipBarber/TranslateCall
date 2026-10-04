import SwiftUI

/// One-line, non-modal TTS notice under the transcription (F8.5.2 REQ-T-41). Renders nothing when nil.
struct TTSNoticeLine: View {
    let text: String?

    var body: some View {
        if let text {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .transition(.opacity)
        }
    }
}

#Preview {
    VStack {
        TTSNoticeLine(text: "Edge TTS unavailable — used system voice")
        TTSNoticeLine(text: nil)
    }
    .padding()
}
