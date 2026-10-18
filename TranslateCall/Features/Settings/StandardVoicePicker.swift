import SwiftUI

/// One "Standard voice for <language>" row (REQ-ST-22). The control follows the engine in effect:
/// an Apple voice picker, Kokoro's variants, or Edge's fixed voice as read-only text.
struct StandardVoicePicker: View {
    let language: Locale.Language
    let languageName: String
    let engine: TTSEngine
    /// The first row explains when these voices are used.
    var showsHint = false
    var installedVoices: [SystemVoice] = SystemVoice.installed

    var body: some View {
        LabeledContent {
            control
        } label: {
            Text("Standard voice for \(languageName)")
                .lineLimit(1).truncationMode(.tail)
            if showsHint {
                Text("Used when “Use my voice” is off.")
            }
        }
    }

    private var locale: Locale { Locale(identifier: language.maximalIdentifier) }

    @ViewBuilder private var control: some View {
        switch engine {
        case .kokoro:
            KokoroVoiceControl(label: String(localized: "Standard voice for \(languageName)"))
        case .edgeTTS:
            Text(StandardVoices.edgeVoiceName(for: locale) ?? "—")
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        case .avSpeech, .voiceClone:
            AppleVoiceControl(
                code: language.languageCode?.identifier ?? language.minimalIdentifier,
                label: String(localized: "Standard voice for \(languageName)"),
                options: StandardVoices.appleOptions(for: locale, installed: installedVoices))
        }
    }
}

/// The Apple voice of one language, kept in `SystemVoicePreference`.
private struct AppleVoiceControl: View {
    let label: String
    let options: [VoiceOption]
    @AppStorage private var voice: String

    init(code: String, label: String, options: [VoiceOption]) {
        self.label = label
        self.options = options
        _voice = AppStorage(wrappedValue: "", SystemVoicePreference.key(for: code))
    }

    var body: some View {
        Picker(label, selection: $voice) {
            ForEach(options) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// Kokoro's voice variant, kept where the engine reads it.
private struct KokoroVoiceControl: View {
    let label: String
    @AppStorage(KokoroConfiguration.voiceDefaultsKey) private var voice = ""

    var body: some View {
        Picker(label, selection: $voice) {
            ForEach(StandardVoices.kokoroOptions) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
        .fixedSize()
    }
}
