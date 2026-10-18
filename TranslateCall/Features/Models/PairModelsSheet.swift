import SwiftUI

extension PairModelsModel: Identifiable {
    nonisolated var id: String { pair.storageKey }
}

/// The "Advanced…" sheet: the engines of one language pair, with their download state (M9 UI settings
/// REQ-ST-10…18). Done stores the staged choice; Cancel drops it. The caller creates the model.
struct PairModelsSheet: View {
    @ObservedObject var model: PairModelsModel
    let onClose: () -> Void
    @EnvironmentObject private var downloads: ModelDownloads

    /// The model for the manager's current pair; also used by the Settings entry (Task 14).
    @MainActor
    static func makeModel(languages: LanguagePairManager, choices: PairModelChoices, cloud: CloudPolicy,
                          downloads: ModelDownloads, tts: TTSEngineSelector) -> PairModelsModel {
        makeModel(source: languages.sourceLanguage, target: languages.targetLanguage, languages: languages,
                  choices: choices, cloud: cloud, downloads: downloads, tts: tts)
    }

    /// The model for any pair, in the given "mine, theirs" order (the pairs list of Settings › Advanced, P13).
    @MainActor
    // swiftlint:disable:next function_parameter_count
    static func makeModel(source: Locale.Language, target: Locale.Language, languages: LanguagePairManager,
                          choices: PairModelChoices, cloud: CloudPolicy, downloads: ModelDownloads,
                          tts: TTSEngineSelector) -> PairModelsModel {
        PairModelsModel(source: source, target: target,
                        displayName: { languages.displayName(for: $0) }, choices: choices, cloud: cloud,
                        downloads: downloads, voiceCloneOn: tts.voiceCloningEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    header
                    section("Speech recognition", icon: "waveform", rows: model.speechRows)
                    translationSection
                    section("Voice when “Use my voice” is off", icon: "speaker.wave.2", rows: model.voiceRows,
                            caption: model.voiceCloneLine)
                }
                .padding(Theme.Spacing.large)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            footer
        }
        .frame(width: 460)
        .onAppear { downloads.refresh() }
        .confirmationDialog("Send text to Microsoft?", isPresented: consentBinding, titleVisibility: .visible) {
            Button("Allow") { model.confirmConsent() }
            Button("Not now", role: .cancel) { model.declineConsent() }
        } message: {
            Text("The translated text is sent to Microsoft to create the voice.")
        }
    }

    private var consentBinding: Binding<Bool> {
        Binding(get: { model.pendingConsent != nil }, set: { if !$0 { model.declineConsent() } })
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.title).font(.headline).lineLimit(1).truncationMode(.tail)
            Text("Recommended models are tested for this pair and run on this Mac. "
                 + "You can choose another one for each step.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var translationSection: some View {
        group("Translation", icon: "globe") {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: "circle.fill").foregroundStyle(Theme.accent).accessibilityHidden(true)
                Text("Apple Translation").fontWeight(.medium).lineLimit(1)
                Text("Recommended").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(Theme.accent).background(Theme.soft(Theme.accent), in: Capsule())
                Text("On-device").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(Theme.Status.green).background(Theme.soft(Theme.Status.green), in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Spacing.small)
        }
    }

    private func section(_ title: LocalizedStringKey, icon: String, rows: [EngineRowState],
                         caption: String? = nil) -> some View {
        group(title, icon: icon, caption: caption) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                EngineRow(row: row, testedLabel: model.testedLabel, blocked: model.downloadsBlocked,
                          onPick: { model.pick(row.engine) }, onCancel: { model.cancel(row.engine) },
                          onRetry: { model.pick(row.engine) })
            }
        }
    }

    private func group<Content: View>(_ title: LocalizedStringKey, icon: String, caption: String? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Label { SectionHeader(title) } icon: { Image(systemName: icon).foregroundStyle(.secondary) }
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, Theme.Spacing.medium)
                .background(Color(.controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .stroke(Color(.separatorColor), lineWidth: 0.5))
        }
    }

    private var footer: some View {
        HStack {
            Button("Reset to recommended") { model.reset() }.buttonStyle(.link)
            Spacer()
            Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
            Button("Done") {
                model.commit()
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Spacing.large)
    }
}
