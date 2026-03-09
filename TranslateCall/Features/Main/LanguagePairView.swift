import SwiftUI

struct LanguagePairView: View {
    @EnvironmentObject private var viewModel: AudioViewModel

    private var manager: LanguagePairManager { viewModel.languagePairManager }

    var body: some View {
        HStack(spacing: 8) {
            languagePicker(
                selection: manager.sourceLanguage,
                onChange: { lang in Task { await manager.setSourceLanguage(lang) } }
            )

            Button {
                Task { await manager.swapLanguages() }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.plain)
            .help("Swap languages")

            languagePicker(
                selection: manager.targetLanguage,
                onChange: { lang in Task { await manager.setTargetLanguage(lang) } }
            )

            pairStatusIndicator

            if manager.pairStatus == .supported {
                Button("Download") {
                    Task { await viewModel.downloadLanguages() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .disabled(viewModel.isCapturing)
    }

    // MARK: - Subviews

    private var pairStatusIndicator: some View {
        Group {
            switch manager.pairStatus {
            case .installed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .supported:
                Image(systemName: "arrow.down.circle").foregroundStyle(.orange)
            case .unsupported:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .unknown:
                ProgressView().scaleEffect(0.6)
            }
        }
        .help(pairStatusHelp)
    }

    private var pairStatusHelp: String {
        switch manager.pairStatus {
        case .installed:   return "Language models installed"
        case .supported:   return "Models need to be downloaded"
        case .unsupported: return "Language pair not supported"
        case .unknown:     return "Checking availability…"
        }
    }

    private func languagePicker(
        selection: Locale.Language,
        onChange: @escaping (Locale.Language) -> Void
    ) -> some View {
        Picker("", selection: Binding(
            get: { selection },
            set: { onChange($0) }
        )) {
            ForEach(manager.supportedLanguages, id: \.minimalIdentifier) { lang in
                Text(manager.displayName(for: lang)).tag(lang)
            }
        }
        .frame(width: 120)
    }
}
