import SwiftUI

struct TranscriptionView: View {
    // MARK: - Outgoing pipeline
    var text: String?
    var isTranscribing: Bool
    var translatedText: String?
    var isTranslating: Bool = false

    // MARK: - Incoming pipeline (shown when isIncomingActive)
    var incomingText: String?
    var incomingTranslation: String?
    var isIncomingActive: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            // MARK: Outgoing section

            Label("↑ Outgoing", systemImage: "mic")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            // Row 1: outgoing transcription
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

            // Row 2: outgoing translation
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

            // MARK: Incoming section (only when active)

            if isIncomingActive {
                Divider()
                    .padding(.vertical, 2)

                Label("↓ Incoming", systemImage: "headphones")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                // Row 3: incoming transcription
                HStack(spacing: 8) {
                    if let incoming = incomingText {
                        Text(incoming)
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

                // Row 4: incoming translation
                HStack(spacing: 8) {
                    if let incomingTr = incomingTranslation {
                        Text(incomingTr)
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
        }
        .frame(minHeight: 52)
        .animation(.default, value: isTranscribing)
        .animation(.default, value: text)
        .animation(.default, value: isTranslating)
        .animation(.default, value: translatedText)
        .animation(.default, value: isIncomingActive)
        .animation(.default, value: incomingText)
        .animation(.default, value: incomingTranslation)
    }
}

#Preview("Idle") {
    TranscriptionView(text: nil, isTranscribing: false)
        .padding()
}

#Preview("Outgoing only") {
    TranscriptionView(
        text: "Hola, ¿cómo estás?",
        isTranscribing: false,
        translatedText: "Hello, how are you?"
    )
    .padding()
}

#Preview("Bidirectional") {
    TranscriptionView(
        text: "Hola, ¿cómo estás?",
        isTranscribing: false,
        translatedText: "Hello, how are you?",
        incomingText: "How is everything going?",
        incomingTranslation: "¿Cómo va todo?",
        isIncomingActive: true
    )
    .padding()
}
