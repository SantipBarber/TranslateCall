import AppKit
import SwiftUI
@preconcurrency import Translation

/// Everything the setup window can do, so the content renders from fixtures in previews.
struct MainSetupActions {
    var select: (CallAppRow) -> Void = { _ in }
    var open: (CallAppRow) -> Void = { _ in }
    var selectOther: (String?) -> Void = { _ in }
    var setUpDriver: () -> Void = {}
    var openVoiceProfiles: () -> Void = {}
    var download: (TranslationSession) async -> Void = { _ in }
    var primary: () -> Void = {}
}

/// The setup window's layout (REQ-UI-01…09): permission cards, call app, cards, languages, voice,
/// the primary button and the footer.
struct MainSetupContent: View {
    let readiness: Readiness
    let pair: PairReadiness
    let isLocked: Bool
    @ObservedObject var monitor: CallAppMonitor
    let selectedBundleID: String?
    @ObservedObject var languages: LanguagePairManager
    @ObservedObject var sttSelector: STTEngineSelector
    @ObservedObject var ttsSelector: TTSEngineSelector
    @ObservedObject var conversationSettings: ConversationSettings
    let profile: VoiceProfileHeader?
    let actions: MainSetupActions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            ForEach(Array(permissionCards.enumerated()), id: \.offset) { PermissionCard(card: $0.element) }
            CallAppSection(monitor: monitor, selectedBundleID: selectedBundleID, onSelect: actions.select,
                           onOpen: actions.open, onSelectOther: actions.selectOther)
            ForEach(Array(otherCards.enumerated()), id: \.offset) { _, card in
                if case .audioDriverMissing = card {
                    AudioDriverCard(card: card, onSetUp: actions.setUpDriver)
                } else {
                    CallAppNotOpenCard(card: card)
                }
            }
            LanguageSection(manager: languages, sttSelector: sttSelector, ttsSelector: ttsSelector, pair: pair,
                            isLocked: isLocked, onDownload: actions.download)
            VoiceSection(ttsSelector: ttsSelector, profile: profile,
                         targetLocale: Locale(identifier: languages.targetLanguage.minimalIdentifier),
                         targetName: languages.displayName(for: languages.targetLanguage),
                         onOpenProfiles: actions.openVoiceProfiles)
            primaryButton
            SetupFooter(settings: conversationSettings)
        }
        .padding(Theme.Spacing.large)
        .frame(width: 420)
    }

    private var permissionCards: [Readiness.Card] {
        readiness.cards.filter { $0 == .microphoneOff || $0 == .screenRecordingOff }
    }

    private var otherCards: [Readiness.Card] {
        readiness.cards.filter { $0 != .microphoneOff && $0 != .screenRecordingOff }
    }

    private var primaryButton: some View {
        Button(action: actions.primary) {
            Label(readiness.primary.title, systemImage: readiness.primary == .stop ? "stop.fill" : "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!readiness.primaryEnabled)
    }
}

/// The setup window: replaces `ContentView` (M9 UI core). Owns the alerts and sheets moved from it.
struct MainSetupView: View {
    @EnvironmentObject private var viewModel: AudioViewModel
    @EnvironmentObject private var setupManager: SetupManager
    @EnvironmentObject private var voiceProfileManager: VoiceProfileManager
    @EnvironmentObject private var sttSelector: STTEngineSelector
    @EnvironmentObject private var ttsSelector: TTSEngineSelector
    @EnvironmentObject private var languages: LanguagePairManager
    @EnvironmentObject private var model: MainSetupModel
    @EnvironmentObject private var session: CallSessionModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(UISettingsKeys.showStatusPanel) private var showStatusPanel = true
    @State private var showSetupWizard = false
    @State private var showVoiceProfiles = false

    var body: some View {
        MainSetupContent(
            readiness: model.readiness, pair: model.pair, isLocked: session.phase != .idle,
            monitor: model.monitor, selectedBundleID: setupManager.selectedCaptureBundleID,
            languages: languages, sttSelector: sttSelector, ttsSelector: ttsSelector,
            conversationSettings: viewModel.conversationSettings, profile: voiceProfileManager.activeProfile,
            actions: actions
        )
        .navigationTitle("TranslateCall")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Label("On-device", systemImage: "lock").font(.caption).foregroundStyle(Theme.Status.green)
            }
        }
        .alert(item: errorAlert, content: Self.alert(for:))
        .alert("Cloud TTS Required", isPresented: $viewModel.showEdgeTTSConsent) {
            Button("Enable") { viewModel.onEdgeTTSConsentResponse(accepted: true) }
            Button("Not Now", role: .cancel) { viewModel.onEdgeTTSConsentResponse(accepted: false) }
        } message: {
            Text("No voice is available for this language on your device. "
                 + "Enable Cloud TTS? Text will be sent to Microsoft for speech synthesis.")
        }
        .sheet(isPresented: $showSetupWizard) {
            SetupWizardView(setupManager: setupManager, isPresented: $showSetupWizard)
        }
        .sheet(isPresented: $showVoiceProfiles) { voiceProfilesSheet }
        .task {
            setupManager.checkBlackHole()
            if !setupManager.isSetupCompleted { showSetupWizard = true }
            await model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { setupManager.checkBlackHole() }
        }
        .onChange(of: session.phase) { _, phase in
            // The panel takes over; with it off the window stays (REQ-UI-40, P22).
            if phase == .running, showStatusPanel { dismissWindow(id: MainWindowOpener.windowID) }
        }
        .onChange(of: languages.sourceLanguage) { _, _ in Task { await model.refresh() } }
        .onChange(of: languages.targetLanguage) { _, _ in Task { await model.refresh() } }
    }

    private var actions: MainSetupActions {
        MainSetupActions(
            select: model.select, open: { row in Task { await model.open(row) } },
            selectOther: model.selectOther(bundleID:), setUpDriver: { showSetupWizard = true },
            openVoiceProfiles: { showVoiceProfiles = true },
            download: { session in
                await viewModel.downloadLanguages(using: session)
                await model.refresh()
            },
            primary: { Task { await model.primaryAction() } }
        )
    }

    /// P14: a start-time failure is shown by the session, not by this alert, while `isStarting`.
    private var errorAlert: Binding<AlertItem?> {
        Binding(get: { viewModel.isStarting ? nil : viewModel.errorAlert },
                set: { viewModel.errorAlert = $0 })
    }

    private static func alert(for alert: AlertItem) -> Alert {
        guard alert.action == .openSettings else {
            return Alert(title: Text(alert.title), message: Text(alert.message))
        }
        return Alert(title: Text(alert.title), message: Text(alert.message),
                     primaryButton: .default(Text("Open Settings")) {
                         NSWorkspace.shared.open(PermissionState.microphoneSettingsURL)
                     },
                     secondaryButton: .cancel())
    }

    private var voiceProfilesSheet: some View {
        NavigationStack {
            VoiceProfileListView(isSessionActive: viewModel.isSessionActive)
                .environmentObject(voiceProfileManager)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showVoiceProfiles = false }
                    }
                }
        }
        .frame(minWidth: 440, minHeight: 400)
    }
}
