import AppKit
import SwiftUI

/// Settings › Advanced (REQ-ST-30…36): models per pair, cloud, speech detection, diagnostics.
struct AdvancedSettingsView: View {
    @EnvironmentObject private var languages: LanguagePairManager
    @EnvironmentObject private var choices: PairModelChoices
    @EnvironmentObject private var cloud: CloudPolicy
    @EnvironmentObject private var downloads: ModelDownloads
    @EnvironmentObject private var tts: TTSEngineSelector
    @EnvironmentObject private var setupManager: SetupManager
    @State private var modelsSheet: PairModelsModel?
    @State private var showSetup = false
    @State private var exportError: String?
    @State private var vad = VADPreference.engine()

    var body: some View {
        AdvancedSettingsContent(
            rows: rows, cloudAllowed: $cloud.allowed,
            vad: Binding(get: { vad }, set: { vad = $0; VADPreference.set($0) }),
            exportError: exportError, onOpen: open, onExport: exportLogs, onRunSetup: { showSetup = true })
            .sheet(item: $modelsSheet) { model in
                PairModelsSheet(model: model, onClose: { modelsSheet = nil })
            }
            .sheet(isPresented: $showSetup) {
                SetupWizardView(setupManager: setupManager, isPresented: $showSetup)
            }
    }

    private var rows: [AdvancedPairRow] {
        let source = PairKey.code(languages.sourceLanguage)
        let pairs = AdvancedPairs.list(current: PairKey(languages.sourceLanguage, languages.targetLanguage),
                                       customized: Array(choices.all.keys))
        return pairs.map { pair in
            let order = AdvancedPairs.ordered(pair, currentSource: source)
            let choice = choices.choice(for: pair)
            return AdvancedPairRow(
                pair: pair, title: "\(name(order.mine)) ↔ \(name(order.theirs))",
                value: AdvancedPairs.value(for: choice), isCustom: choice.stt != nil || choice.voice != nil)
        }
    }

    private func name(_ code: String) -> String { languages.displayName(for: Locale.Language(identifier: code)) }

    private func open(_ pair: PairKey) {
        let order = AdvancedPairs.ordered(pair, currentSource: PairKey.code(languages.sourceLanguage))
        modelsSheet = PairModelsSheet.makeModel(
            source: Locale.Language(identifier: order.mine), target: Locale.Language(identifier: order.theirs),
            languages: languages, choices: choices, cloud: cloud, downloads: downloads, tts: tts)
    }

    /// `LogExporter.entries()` can be slow, so it runs off the main actor; the panel and the write come back.
    private func exportLogs() {
        exportError = nil
        Task {
            do {
                let lines = try await Task.detached { try LogExporter.entries() }.value
                let panel = NSSavePanel()
                panel.nameFieldStringValue = LogExporter.fileName(on: .now)
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try LogExporter.text(lines).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

/// One pair of the list, ready to show.
struct AdvancedPairRow: Identifiable {
    let pair: PairKey
    let title: String
    let value: String
    let isCustom: Bool
    var id: PairKey { pair }
}

/// The form itself, free of environment so previews render it from fixtures.
struct AdvancedSettingsContent: View {
    let rows: [AdvancedPairRow]
    @Binding var cloudAllowed: Bool
    @Binding var vad: VADEngine
    let exportError: String?
    let onOpen: (PairKey) -> Void
    let onExport: () -> Void
    let onRunSetup: () -> Void

    @AppStorage("ui.showMetrics") private var showMetrics = false

    var body: some View {
        Form {
            Section {
                ForEach(rows) { row in
                    PairRow(title: row.title, value: row.value, isCustom: row.isCustom) { onOpen(row.pair) }
                }
            } header: {
                Text("Models per language pair")
            } footer: {
                Text("Recommended models are tested for each pair. Change them only if something doesn't sound right.")
            }
            Section("Cloud") {
                Toggle(isOn: $cloudAllowed) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow cloud models")
                        Text("Off: everything runs on this Mac. On: cloud models appear in the model lists, "
                             + "and each one asks for your consent the first time.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Speech detection") {
                Picker("Voice detector", selection: $vad) {
                    Text("Silero (recommended)").tag(VADEngine.silero)
                    Text("Basic (energy)").tag(VADEngine.energy)
                }
            }
            Section("Diagnostics") {
                Toggle(isOn: $showMetrics) {
                    labelled("Show speech and voice metrics", "Timings for each sentence, for troubleshooting.")
                }
                if showMetrics {
                    STTMetricsView()
                    TTSMetricsView()
                    TTSMonitorRow()
                }
                LabeledContent {
                    Button("Export logs…", action: onExport)
                } label: {
                    labelled("Logs", "Logs since TranslateCall started.")
                }
                if let exportError {
                    Text(exportError).font(.caption).foregroundStyle(Theme.Status.red)
                }
                LabeledContent {
                    Button("Run setup again…", action: onRunSetup)
                } label: {
                    labelled("Setup", "Permissions, audio cable and call app microphone.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func labelled(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
extension AdvancedSettingsContent {
    @MainActor static func fixture(custom: Bool = false, metrics: Bool = false) -> some View {
        let defaults = UserDefaults(suiteName: "preview.advanced") ?? .standard
        defaults.set(metrics, forKey: "ui.showMetrics")
        let rows = [
            AdvancedPairRow(pair: PairKey("es", "de"), title: "Español ↔ Deutsch",
                            value: "Recommended", isCustom: false),
            AdvancedPairRow(pair: PairKey("es", "en"), title: "Español ↔ English",
                            value: custom ? "Custom · Apple Speech" : "Recommended", isCustom: custom),
            AdvancedPairRow(pair: PairKey("de", "en"), title: "Deutsch ↔ English",
                            value: "Recommended", isCustom: false)
        ]
        return AdvancedSettingsContent(
            rows: rows, cloudAllowed: .constant(false), vad: .constant(.silero), exportError: nil,
            onOpen: { _ in }, onExport: {}, onRunSetup: {})
            .environmentObject(AudioViewModel.preview())
            .defaultAppStorage(defaults)
            .frame(width: 560, height: metrics ? 760 : 560)
    }
}

#Preview("All recommended — light") { AdvancedSettingsContent.fixture().preferredColorScheme(.light) }
#Preview("One pair custom — dark") { AdvancedSettingsContent.fixture(custom: true).preferredColorScheme(.dark) }
#Preview("Metrics on — light") { AdvancedSettingsContent.fixture(metrics: true).preferredColorScheme(.light) }
#endif
