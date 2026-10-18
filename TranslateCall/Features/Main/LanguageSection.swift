import SwiftUI
@preconcurrency import Translation

/// "I speak" / "They speak", the swap button and the pair's status line (REQ-UI-05…07, 33).
struct LanguageSection: View {
    @ObservedObject var manager: LanguagePairManager
    let pair: PairReadiness
    /// "Models: Recommended" / "Models: Custom" (· Cloud), from `MainSetupModel.modelsLabel`.
    let modelsLabel: String
    /// "Advanced…": opens the pair's models (P10).
    let onAdvanced: () -> Void
    /// True while a session is starting, launching or running.
    let isLocked: Bool
    /// Runs the system download with the view's own session (F8.5.4 REQ-TR-40), then re-checks the pair.
    let onDownload: (TranslationSession) async -> Void
    /// Set by "Download"; drives this view's own `.translationTask`. Nil when idle.
    @State private var downloadConfiguration: TranslationSession.Configuration?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader("Languages")
            HStack(spacing: Theme.Spacing.small) {
                picker(caption: "I speak", selection: manager.sourceLanguage) { lang in
                    Task { await manager.setSourceLanguage(lang) }
                }
                Button { Task { await manager.swapLanguages() } } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .help("Swap languages")
                .accessibilityLabel("Swap languages")
                picker(caption: "They speak", selection: manager.targetLanguage) { lang in
                    Task { await manager.setTargetLanguage(lang) }
                }
            }
            statusLine
        }
        .disabled(isLocked)
        // Runs in the visible window so the system download sheet appears here (REQ-TR-40).
        .translationTask(downloadConfiguration) { session in
            await onDownload(session)
            downloadConfiguration = nil
        }
    }

    // MARK: Pickers

    private func picker(caption: LocalizedStringKey, selection: Locale.Language,
                        onChange: @escaping (Locale.Language) -> Void) -> some View {
        let groups = LanguageOrdering.ordered(manager.supportedLanguages, displayName: manager.displayName(for:))
        let binding = Binding(get: { selection }, set: onChange)
        return Menu {
            Picker(caption, selection: binding) {
                ForEach(groups.priority, id: \.minimalIdentifier) { Text(manager.displayName(for: $0)).tag($0) }
                if !groups.priority.isEmpty, !groups.others.isEmpty { Divider() }
                ForEach(groups.others, id: \.minimalIdentifier) { Text(manager.displayName(for: $0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(manager.displayName(for: selection)).fontWeight(.semibold)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .frame(maxWidth: .infinity)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .stroke(Color(.separatorColor), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(Text(caption))
        .accessibilityValue(manager.displayName(for: selection))
    }

    // MARK: Status

    @ViewBuilder
    private var statusLine: some View {
        switch pair {
        case .ready: readyLine
        case .missing(let language): downloadCard(language: language)
        case .unsupported:
            Label("This pair isn't available", systemImage: "xmark.circle.fill")
                .font(.callout).foregroundStyle(Theme.Status.red)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking languages…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var readyLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Status.green)
            Text("Ready").font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: Theme.Spacing.small)
            Text(modelsLabel)
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Text("·").foregroundStyle(.secondary)
            Button("Advanced…", action: onAdvanced)
                .buttonStyle(.link)
                .font(.callout)
        }
    }

    private func downloadCard(language: String) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(language) needs a one-time download").fontWeight(.semibold)
                Text("After that it works offline").font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Spacing.small)
            Button("Download") {
                downloadConfiguration = .init(source: manager.sourceLanguage, target: manager.targetLanguage)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(Theme.Spacing.medium)
        .background(Theme.soft(Theme.accent))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            .stroke(Theme.accent.opacity(0.4), lineWidth: 0.5))
    }
}
