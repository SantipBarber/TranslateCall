import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// The languages whose models are installed for `source` (P17): there is no list API, so each supported
/// language is asked through `isInstalled`. Pure so the tests inject both closures.
nonisolated enum DownloadedLanguages {
    static func list(
        source: Locale.Language,
        supported: [Locale.Language],
        displayName: (Locale.Language) -> String,
        isInstalled: (Locale.Language, Locale.Language) async -> Bool
    ) async -> [String] {
        var names: Set<String> = [displayName(source)]
        for language in supported where language.minimalIdentifier != source.minimalIdentifier {
            if await isInstalled(source, language) { names.insert(displayName(language)) }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// "Open at login" over `SMAppService.mainApp`, injectable so tests and previews never touch the system.
@MainActor
final class OpenAtLoginModel: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var errorMessage: String?
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    private let readEnabled: () -> Bool

    init(
        isEnabled: @escaping () -> Bool = { SMAppService.mainApp.status == .enabled },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) {
        self.readEnabled = isEnabled
        self.register = register
        self.unregister = unregister
        self.isEnabled = isEnabled()
    }

    func set(_ enabled: Bool) {
        do {
            if enabled { try register() } else { try unregister() }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isEnabled = readEnabled()
    }
}

/// Settings > General (REQ-UI-71): audio, rhythm, status panel and general options.
struct GeneralSettingsView: View {
    @EnvironmentObject private var viewModel: AudioViewModel
    @EnvironmentObject private var languages: LanguagePairManager
    @EnvironmentObject private var session: CallSessionModel
    @StateObject private var login = OpenAtLoginModel()
    @State private var downloaded: [String] = []

    nonisolated static func pauseValueLabel(_ seconds: Double) -> String {
        String(format: "%.1f s pause", seconds)
    }

    var body: some View {
        GeneralSettingsContent(
            viewModel: viewModel, settings: viewModel.conversationSettings, login: login,
            canShowLatency: session.latency.canProvide, downloadedLanguages: downloaded,
            onManageLanguages: Self.openLanguageSettings)
            .task(id: "\(languages.sourceLanguage.minimalIdentifier)/\(languages.supportedLanguages.count)") {
                downloaded = await DownloadedLanguages.list(
                    source: languages.sourceLanguage, supported: languages.supportedLanguages,
                    displayName: languages.displayName(for:), isInstalled: AppleTranslationService.isInstalled)
            }
    }

    private static func openLanguageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The form itself, free of environment so previews render it from fixtures.
struct GeneralSettingsContent: View {
    @ObservedObject var viewModel: AudioViewModel
    @ObservedObject var settings: ConversationSettings
    @ObservedObject var login: OpenAtLoginModel
    let canShowLatency: Bool
    let downloadedLanguages: [String]
    let onManageLanguages: () -> Void
    @AppStorage(UISettingsKeys.showStatusPanel) private var showStatusPanel = true
    @AppStorage(UISettingsKeys.showLatency) private var showLatency = true

    var body: some View {
        Form {
            audioSection
            rhythmSection
            translatingSection
            generalSection
        }
        .formStyle(.grouped)
    }

    private var audioSection: some View {
        Section {
            Picker("I listen with", selection: $settings.listeningMode) {
                Label("Headphones", systemImage: "headphones").tag(ListeningMode.headphones)
                Label("Speakers", systemImage: "hifispeaker").tag(ListeningMode.speakers)
            }
            .pickerStyle(.segmented)
            Picker("Microphone", selection: Binding(
                get: { viewModel.selectedInput },
                set: { if let device = $0 { viewModel.selectInput(device) } })) {
                ForEach(viewModel.inputDevices) { Text($0.name).tag(Optional($0)) }
            }
            Picker("Their voice plays on", selection: Binding(
                get: { viewModel.selectedOutput },
                set: { if let device = $0 { viewModel.selectOutput(device) } })) {
                ForEach(viewModel.outputDevices) { Text($0.name).tag(Optional($0)) }
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("In speaker mode your microphone pauses while their translation plays, "
                + "so it doesn't translate itself.")
        }
    }

    private var rhythmSection: some View {
        Section("Rhythm") {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("When to translate")
                Text("How long you pause before TranslateCall translates what you said")
                    .font(.caption).foregroundStyle(.secondary)
                Slider(value: $settings.pauseSeconds, in: ConversationSettings.pauseRange,
                       step: ConversationSettings.pauseStep) {
                    Text("When to translate")
                } minimumValueLabel: {
                    Text("Faster replies").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("Wait for full sentences").font(.caption).foregroundStyle(.secondary)
                }
                .labelsHidden()
                Text(GeneralSettingsView.pauseValueLabel(settings.pauseSeconds))
                    .font(.caption).fontWeight(.semibold).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var translatingSection: some View {
        Section("While translating") {
            Toggle("Show the status panel", isOn: $showStatusPanel)
            if canShowLatency {
                Toggle(isOn: $showLatency) {
                    Text("Show latency in the panel")
                    Text("Small grey number next to each direction")
                }
            }
        }
    }

    private var generalSection: some View {
        Section("General") {
            Toggle("Open at login", isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
            if let error = login.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            LabeledContent {
                Button("Manage…", action: onManageLanguages).buttonStyle(.link)
            } label: {
                Text("Downloaded languages")
                Text(downloadedLanguages.joined(separator: ", "))
            }
        }
    }
}

#Preview("Light") {
    GeneralSettingsContent.fixture().preferredColorScheme(.light)
}

#Preview("Dark") {
    GeneralSettingsContent.fixture().preferredColorScheme(.dark)
}

extension GeneralSettingsContent {
    @MainActor static func fixture(canShowLatency: Bool = true) -> some View {
        GeneralSettingsContent(
            viewModel: .preview(),
            settings: ConversationSettings(defaults: UserDefaults(suiteName: "preview.general") ?? .standard),
            login: OpenAtLoginModel(isEnabled: { false }, register: {}, unregister: {}),
            canShowLatency: canShowLatency, downloadedLanguages: ["Deutsch", "English", "Español"],
            onManageLanguages: {})
            .frame(width: 560)
    }
}
