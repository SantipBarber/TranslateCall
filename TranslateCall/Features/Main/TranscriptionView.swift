import SwiftUI

struct TranscriptionView: View {
    var text: String?
    var isTranscribing: Bool
    var translatedText: String?
    var isTranslating: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Original transcription row
            HStack(spacing: 8) {
                if isTranscribing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let text {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }

            // Translation row
            HStack(spacing: 8) {
                if isTranslating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Translating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let translated = translatedText {
                    Text(translated)
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Color.clear.frame(height: 1)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: 52)
        .animation(.default, value: isTranscribing)
        .animation(.default, value: text)
        .animation(.default, value: isTranslating)
        .animation(.default, value: translatedText)
    }
}

#Preview("Idle") {
    TranscriptionView(text: nil, isTranscribing: false)
        .padding()
}

#Preview("Transcribing") {
    TranscriptionView(text: nil, isTranscribing: true)
        .padding()
}

#Preview("Result only") {
    TranscriptionView(text: "Hola, ¿cómo estás?", isTranscribing: false)
        .padding()
}

#Preview("Translating") {
    TranscriptionView(text: "Hola, ¿cómo estás?", isTranscribing: false, isTranslating: true)
        .padding()
}

#Preview("Full pipeline") {
    TranscriptionView(
        text: "Hola, ¿cómo estás?",
        isTranscribing: false,
        translatedText: "Hello, how are you?",
        isTranslating: false
    )
    .padding()
}
