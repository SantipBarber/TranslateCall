import SwiftUI

// MARK: - KokoroVoicePicker

/// Voice variant picker for the Kokoro on-device TTS model.
struct KokoroVoicePicker: View {
    @AppStorage(KokoroConfiguration.voiceDefaultsKey) private var voice: String = ""

    private let voices: [(id: String, label: String)] = [
        ("", "Default (af_heart)"),
        ("af_heart", "af_heart"),
        ("af_bella", "af_bella"),
        ("am_adam", "am_adam"),
        ("am_michael", "am_michael")
    ]

    var body: some View {
        Picker("Voice", selection: $voice) {
            ForEach(voices, id: \.id) { item in
                Text(item.label).tag(item.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 140)
        .help("Kokoro voice variant")
    }
}

#Preview {
    KokoroVoicePicker()
        .padding()
}
