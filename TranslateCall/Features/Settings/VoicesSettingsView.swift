import SwiftUI

/// Settings › Voices (REQ-ST-20…22): the recorded voices and the standard voice of each language.
struct VoicesSettingsView: View {
    @EnvironmentObject private var voiceProfileManager: VoiceProfileManager
    @EnvironmentObject private var ttsSelector: TTSEngineSelector
    @EnvironmentObject private var languages: LanguagePairManager
    @EnvironmentObject private var viewModel: AudioViewModel
    @State private var previewService: VoicePreviewService?
    @State private var showRecordSheet = false

    var body: some View {
        VoicesSettingsContent(
            profiles: voiceProfileManager.profiles, activeProfileId: voiceProfileManager.activeProfileId,
            rows: standardRows,
            onUse: { voiceProfileManager.setActiveProfile($0) }, onPlay: play,
            onRename: { id, name in Task { try? await voiceProfileManager.rename(id: id, newName: name) } },
            onDelete: { id in Task { try? await voiceProfileManager.delete(id: id) } },
            onRecord: { showRecordSheet = true })
            .sheet(isPresented: $showRecordSheet) { recordSheet }
            .onAppear {
                if previewService == nil {
                    previewService = try? VoicePreviewService(profileStore: voiceProfileManager.profileStore)
                }
            }
    }

    /// Their language first, then mine, as in the prototype.
    private var standardRows: [StandardVoiceRow] {
        return [
            row(languages.targetLanguage, direction: .outgoing),
            row(languages.sourceLanguage, direction: .incoming)
        ]
    }

    private func row(_ language: Locale.Language, direction: TranscriptDirection) -> StandardVoiceRow {
        StandardVoiceRow(language: language, name: languages.displayName(for: language),
                         engine: ttsSelector.standardEngine(for: locale(language), direction: direction))
    }

    private func locale(_ language: Locale.Language) -> Locale { Locale(identifier: language.maximalIdentifier) }

    private func play(_ id: UUID) {
        guard !viewModel.isSessionActive else { return }
        Task { await previewService?.playRecording(profileId: id) }
    }

    private var recordSheet: some View {
        NavigationStack {
            VoiceProfileListView(isSessionActive: viewModel.isSessionActive)
                .environmentObject(voiceProfileManager)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showRecordSheet = false }
                    }
                }
        }
        .frame(minWidth: 440, minHeight: 400)
    }
}

/// One "Standard voice for <language>" row's inputs.
struct StandardVoiceRow: Identifiable {
    let language: Locale.Language
    let name: String
    let engine: TTSEngine
    var id: String { language.minimalIdentifier }
}

/// The form itself, free of environment so previews render it from fixtures.
struct VoicesSettingsContent: View {
    let profiles: [VoiceProfileHeader]
    let activeProfileId: UUID?
    let rows: [StandardVoiceRow]
    let onUse: (UUID) -> Void
    let onPlay: (UUID) -> Void
    let onRename: (UUID, String) -> Void
    let onDelete: (UUID) -> Void
    let onRecord: () -> Void
    var installedVoices: [SystemVoice] = SystemVoice.installed

    @State private var renameTarget: VoiceProfileHeader?
    @State private var renameText = ""
    @State private var deleteTarget: VoiceProfileHeader?

    var body: some View {
        Form {
            Section {
                ForEach(profiles) { profile in
                    VoiceProfileRow(
                        profile: profile, isActive: profile.id == activeProfileId,
                        onUse: { onUse(profile.id) }, onPlay: { onPlay(profile.id) },
                        onRename: { renameText = profile.name; renameTarget = profile },
                        onDelete: { deleteTarget = profile })
                }
                Button(action: onRecord) {
                    Label("Record a new voice…", systemImage: "plus")
                }
                .buttonStyle(.link)
            } header: {
                Text("Your voices")
            } footer: {
                Text("The voice used when “Use my voice” is on. Voices are stored only on this Mac.")
            }
            Section("Without my voice") {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    StandardVoicePicker(language: row.language, languageName: row.name, engine: row.engine,
                                        showsHint: index == 0, installedVoices: installedVoices)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Rename voice", isPresented: Binding(get: { renameTarget != nil },
                                                    set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let target = renameTarget, !name.isEmpty { onRename(target.id, name) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "Delete this voice?", isPresented: Binding(get: { deleteTarget != nil },
                                                       set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget) { target in
            Button("Delete “\(target.name)”", role: .destructive) { onDelete(target.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The recording is removed from this Mac.")
        }
    }
}

// MARK: - Previews

#Preview("Light") { VoicesSettingsContent.fixture().preferredColorScheme(.light) }
#Preview("Dark") { VoicesSettingsContent.fixture().preferredColorScheme(.dark) }
#Preview("No voices") { VoicesSettingsContent.fixture(profiles: []).preferredColorScheme(.light) }
#Preview("Kokoro") {
    VoicesSettingsContent.fixture(engines: (.avSpeech, .kokoro)).preferredColorScheme(.dark)
}
#Preview("Edge") {
    VoicesSettingsContent.fixture(engines: (.edgeTTS, .avSpeech)).preferredColorScheme(.light)
}

extension VoicesSettingsContent {
    private static func header(_ name: String, daysAgo: Int, seconds: Float) -> VoiceProfileHeader {
        VoiceProfileHeader(
            id: UUID(), name: name, createdAt: Date().addingTimeInterval(Double(-daysAgo) * 86_400),
            durationSeconds: seconds, sampleRate: 24_000, sampleCount: Int(seconds) * 24_000,
            quality: VoiceQualityMetrics(peakRmsDbfs: -18, hasClipping: false, voicedDurationSeconds: seconds,
                                         grade: .good),
            formatVersion: 1)
    }

    @MainActor static func fixture(
        profiles: [VoiceProfileHeader]? = nil, engines: (TTSEngine, TTSEngine) = (.avSpeech, .avSpeech)
    ) -> some View {
        let list = profiles ?? [header("Santi", daysAgo: 6, seconds: 48),
                                header("Santi (headset)", daysAgo: 18, seconds: 41)]
        return VoicesSettingsContent(
            profiles: list, activeProfileId: list.first?.id,
            rows: [StandardVoiceRow(language: Locale.Language(identifier: "de"), name: "Deutsch", engine: engines.0),
                   StandardVoiceRow(language: Locale.Language(identifier: "es"), name: "Español", engine: engines.1)],
            onUse: { _ in }, onPlay: { _ in }, onRename: { _, _ in }, onDelete: { _ in }, onRecord: {},
            installedVoices: [SystemVoice(identifier: "a", name: "Anna", language: "de-DE", quality: 1),
                              SystemVoice(identifier: "m", name: "Mónica", language: "es-ES", quality: 1)])
            .frame(width: 560)
    }
}
