import SwiftUI

/// First screen of "New voice": read a short text (recommended) or record freely (REQ-QS-10).
struct GuidedRecordingChoiceView: View {
    let onGuided: () -> Void
    let onFree: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            Image(systemName: "mic.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("New voice")
                .font(.headline)

            Text("A short reading is enough for your voice to sound like you, and it answers faster.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: Theme.Spacing.small) {
                Button(action: onGuided) {
                    Label("Read a short text (recommended)", systemImage: "text.quote")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onFree) {
                    Label("Use my own text", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: 420)
    }
}

/// Guided step before recording: pick the language and see the text that will be read.
struct GuidedReadingSetupView: View {
    @Binding var language: String
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            Text("Read a short text")
                .font(.headline)

            Picker("Language", selection: $language) {
                ForEach(QwenCloneConfiguration.supportedLanguageList, id: \.key) { entry in
                    Text(LocalizedStringKey(entry.label)).tag(entry.key)
                }
            }
            .frame(maxWidth: 280)

            Text(GuidedReadingTexts.text(for: language))
                .font(.title3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(Theme.Spacing.large)
                .background(Theme.soft(Theme.accent), in: RoundedRectangle(cornerRadius: Theme.Radius.large))

            Text("You will read this aloud for about 8 seconds, in a quiet room.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Start Recording", action: onStart)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(24)
    }
}

#Preview("Choice, light") { GuidedRecordingChoiceView(onGuided: {}, onFree: {}).preferredColorScheme(.light) }
#Preview("Choice, dark") { GuidedRecordingChoiceView(onGuided: {}, onFree: {}).preferredColorScheme(.dark) }
#Preview("Setup, dark") {
    GuidedReadingSetupView(language: .constant("spanish"), onStart: {})
        .frame(width: 440)
        .preferredColorScheme(.dark)
}
