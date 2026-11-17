import AppKit
import SwiftUI

/// Step 4: the test card and the checks (REQ-FR-40…58). Pure inputs, so it renders from fixtures;
/// `TestStepView` binds it to the live checks and rehearsal.
struct TestStepContent: View {
    let myLanguage: String
    let appName: String
    let rehearsal: RehearsalState
    let micState: CheckState
    let routeState: CheckState
    let levels: [Float]
    let onRehearse: () -> Void
    let onPlay: () -> Void
    let onRunRoute: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SetupStepHeader(
                title: String(localized: "Let's check it works"),
                subtitle: String(localized: """
                    Say something in \(myLanguage). You'll see what TranslateCall understood and what \
                    \(appName) will receive.
                    """))
            RehearsalBox(state: rehearsal, micState: micState, levels: levels, appName: appName,
                         myLanguage: myLanguage, routeBusy: routeState == .running,
                         onRehearse: onRehearse, onPlay: onPlay)
            VStack(alignment: .leading, spacing: 8) {
                micRow
                routeRow
                CheckRow(symbol: "hourglass", color: .secondary, title: nil,
                         text: TestStepPresentation.incomingLine(appName: appName), accessibility: String(
                            localized: "Incoming audio from \(appName): checked in your first call"))
            }
        }
    }

    private var micRow: some View {
        CheckRow(symbol: Self.symbol(micState), color: Self.color(micState), title: nil,
                 text: TestStepPresentation.micLine(micState),
                 accessibility: String(localized: "Microphone: \(TestStepPresentation.micLine(micState))"))
    }

    /// The rehearsal runs or asks for consent: both use BlackHole, so the route test waits.
    private var rehearsalBusy: Bool { rehearsal.isRunning || rehearsal == .needsConsent }

    private var routeRow: some View {
        let title = String(localized: "Translated voice reaches BlackHole")
        let line = TestStepPresentation.routeLine(routeState)
        return CheckRow(symbol: Self.symbol(routeState), color: Self.color(routeState),
                        title: routeState == .idle ? title : nil,
                        text: routeState == .idle ? nil : line,
                        accessibility: "\(title): \(routeState == .idle ? String(localized: "not tested") : line)") {
            if routeState == .idle {
                Button(line, action: onRunRoute).controlSize(.small).disabled(rehearsalBusy)
            } else if case .failed = routeState {
                Button("Try again", action: onRunRoute).controlSize(.small).disabled(rehearsalBusy)
            }
        }
    }

    static func symbol(_ state: CheckState) -> String {
        switch state {
        case .idle, .running: "circle"
        case .passed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        }
    }

    static func color(_ state: CheckState) -> Color {
        switch state {
        case .idle, .running: .secondary
        case .passed: Theme.Status.green
        case .failed: Theme.Status.orange
        }
    }
}

private struct CheckRow<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String?
    let text: String?
    let accessibility: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(color)
                .frame(width: 16).accessibilityHidden(true)
            if let title { Text(title).font(.system(size: 12)) }
            if let text {
                Text(text).font(.system(size: 12)).foregroundStyle(title == nil ? .primary : .secondary)
            }
            trailing
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibility))
        .accessibilityAddTraits(.isStaticText)
    }
}

extension CheckRow where Trailing == EmptyView {
    init(symbol: String, color: Color, title: String?, text: String?, accessibility: String) {
        self.init(symbol: symbol, color: color, title: title, text: text, accessibility: accessibility) {
            EmptyView()
        }
    }
}

/// The live step 4: starts the mic check on entry, stops everything on exit (REQ-FR-57).
struct TestStepView: View {
    @ObservedObject var checks: SetupChecks
    @ObservedObject var rehearsal: Rehearsal
    @EnvironmentObject private var model: MainSetupModel
    @EnvironmentObject private var setupManager: SetupManager
    @EnvironmentObject private var languagePairManager: LanguagePairManager
    @EnvironmentObject private var callSession: CallSessionModel
    @EnvironmentObject private var downloads: ModelDownloads
    @State private var permissions = PermissionState.current()
    @State private var levels: [Float] = []
    @State private var showConsent = false
    /// False once the step is left: nothing may restart the mic check then.
    @State private var isVisible = false

    var body: some View {
        TestStepContent(myLanguage: languagePairManager.displayName(for: languagePairManager.sourceLanguage),
                        appName: model.selectedRow?.appName ?? String(localized: "your call app"),
                        rehearsal: rehearsal.state, micState: checks.micState, routeState: checks.routeState,
                        levels: levels, onRehearse: rehearse, onPlay: rehearsal.playResult,
                        onRunRoute: runRoute)
            .onAppear {
                isVisible = true
                rehearsal.refresh(availability: availability)
                checks.startMicCheck()
            }
            .onDisappear {
                isVisible = false
                stop()
            }
            .onChange(of: availability) { _, new in rehearsal.refresh(availability: new) }
            .onChange(of: callSession.phase) { old, phase in
                if [.launching, .starting, .running].contains(phase) { stop() }
                if isVisible, TestStepPresentation.restartsMicCheck(from: old, to: phase) { checks.startMicCheck() }
            }
            .onChange(of: checks.micLevel) { _, level in
                levels = Array((levels + [level]).suffix(LevelMeterView.barCount))
            }
            .onChange(of: rehearsal.state) { old, new in
                if new == .needsConsent { showConsent = true }
                if isVisible, TestStepPresentation.restartsMicCheck(from: old, to: new) { checks.startMicCheck() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                permissions = PermissionState.current()
            }
            .alert("Enable Cloud TTS?", isPresented: $showConsent) {
                Button("Enable") { rehearsal.consent(accepted: true) }
                Button("Cancel", role: .cancel) { rehearsal.consent(accepted: false) }
            } message: {
                Text(TestStepPresentation.consentMessage)
            }
    }

    /// Why the rehearsal cannot run now; the pair and download part is derived like the main window's.
    private var availability: String? {
        let phase: SessionPhase = callSession.phase == .rehearsing ? .idle : callSession.phase
        let readiness = Readiness.derive(
            permissions: permissions, blackHolePresent: setupManager.isBlackHolePresent, pair: model.pair, app: nil,
            phase: .idle, modelDownloading: downloads.states.values.contains(where: \.isDownloading))
        return Rehearsal.availability(phase: phase, readiness: readiness,
                                      blackHolePresent: setupManager.isBlackHolePresent,
                                      microphone: permissions.microphone)
    }

    /// The mic check stops first: the rehearsal opens the microphone itself. Never while the route
    /// test runs: both use BlackHole.
    private func rehearse() {
        guard checks.routeState != .running else { return }
        checks.stopMicCheck()
        rehearsal.rehearse()
        if !rehearsal.state.isRunning, rehearsal.state != .needsConsent { checks.startMicCheck() }
    }

    private func runRoute() {
        guard !rehearsal.state.isRunning, rehearsal.state != .needsConsent else { return }
        Task { await checks.runRouteCheck() }
    }

    private func stop() {
        let (checks, rehearsal) = (checks, rehearsal)
        checks.cancelAll()
        Task { await rehearsal.cancel() }
    }
}
