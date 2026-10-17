import AppKit
import Combine
import Foundation

// MARK: - CallSessionModel

/// In-call state for the status panel and the menu bar popover (M9 UI core REQ-UI-40…52, 60).
///
/// Derived from `AudioCoordinator`'s published state on the next main-queue turn after each
/// change. Kept apart from `AudioViewModel`, which is at its file-length limit.
@MainActor
final class CallSessionModel: ObservableObject {
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var outgoing: DirectionState = .listening
    @Published private(set) var incoming: DirectionState = .listening
    @Published private(set) var incomingStatus: IncomingStatus = .idle
    @Published private(set) var title: PanelTitle = .translating
    @Published private(set) var isPaused = false
    @Published private(set) var transcript: [TranscriptEntry] = []
    @Published private(set) var sessionStartedAt: Date?
    /// Up to two lines under the direction rows (REQ-UI-45).
    @Published private(set) var notices: [String] = []
    /// A mid-call error shown as a notice instead of an alert (REQ-UI-36/82).
    @Published private(set) var panelNotice: String?
    /// A sentence is being translated in either direction (the transcript's "Translating…" capsule).
    @Published private(set) var isTranslating = false

    let coordinator: AudioCoordinator
    let viewModel: AudioViewModel
    let latency: any LatencyProvider
    private let noticeDuration: Duration
    private let clock: any Clock<Duration>
    private var noticeTask: Task<Void, Never>?
    /// Which transient notice is newest: the TTS line or the panel notice.
    private var newestTransient: String?
    /// The last `ttsNotice` seen, so a still-showing TTS line is not re-promoted over a newer notice.
    private var lastTTSNotice: String?
    /// "Open <App> and start" is waiting for the app: a second press is ignored (P24).
    private var isLaunching = false
    /// Brings up the main window for an alert of a start that did not go active (P27).
    private let openMainWindow: () -> Void
    /// The alert the main window was last brought up for: once per alert.
    private var windowOpenedForAlert: AlertItem.ID?
    private var cancellables: Set<AnyCancellable> = []

    init(coordinator: AudioCoordinator, viewModel: AudioViewModel, latency: any LatencyProvider = NoLatencyProvider(),
         noticeDuration: Duration = .seconds(8), clock: any Clock<Duration> = ContinuousClock(),
         openMainWindow: @escaping () -> Void = { NSApp.showMainWindow() }) {
        self.coordinator = coordinator
        self.viewModel = viewModel
        self.latency = latency
        self.noticeDuration = noticeDuration
        self.clock = clock
        self.openMainWindow = openMainWindow
        coordinator.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        viewModel.conversationSettings.$listeningMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        viewModel.$errorAlert
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        recompute()
    }

    // MARK: Actions

    func togglePause() async {
        if coordinator.isPaused { coordinator.resume() } else { await coordinator.pause() }
    }

    func stop() async {
        guard coordinator.isOutgoingActive || coordinator.isStarting else { return }
        await coordinator.stop()
    }

    /// "Skip my next sentence" (was Mute Turn, REQ-UI-80a).
    func skipNextSentence() { viewModel.muteTurn() }

    /// Start, launching the call app first when it is installed but not running (REQ-UI-34).
    /// After at most `timeout` the session starts anyway; incoming then shows "Can't hear".
    /// While the app launches, `phase` is `.launching` and another Start is ignored (P24).
    func start(launching app: CallAppRow?, monitor: CallAppMonitor, timeout: Duration = .seconds(15)) async {
        guard !isLaunching, !coordinator.isOutgoingActive, !coordinator.isStarting else { return }
        if let app, !app.isRunning, app.appURL != nil {
            isLaunching = true
            recompute()
            await monitor.open(app)
            _ = await monitor.waitUntilRunning(bundleID: app.bundleID, timeout: timeout)
            isLaunching = false
            recompute()
        }
        // Another entry point (menu bar, popover) may have started it during the wait: toggling would stop it.
        guard !coordinator.isOutgoingActive, !coordinator.isStarting else { return }
        await viewModel.toggleCapture()
    }

    /// "mm:ss" (or "h:mm:ss") since `start`.
    nonisolated static func elapsedText(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                         : String(format: "%02d:%02d", minutes, seconds)
    }

    /// The standing speakers line first, then the newest transient notice (REQ-UI-45).
    nonisolated static func composeNotices(listeningMode: ListeningMode, transient: String?) -> [String] {
        var lines: [String] = []
        if listeningMode == .speakers {
            lines.append(String(localized: "Your mic pauses while their translation plays (speakers on)"))
        }
        if let transient { lines.append(transient) }
        return lines
    }

    // MARK: Derivation

    /// Assigns only real changes: every coordinator tick lands here, and an unchanged `@Published`
    /// assignment would still re-render every observing view.
    private func recompute() {
        let coordinator = coordinator
        set(\.phase, Self.phase(launching: isLaunching, starting: coordinator.isStarting,
                                active: coordinator.isOutgoingActive))
        set(\.isPaused, coordinator.isPaused)
        set(\.incomingStatus, coordinator.incomingStatus)
        set(\.outgoing, .outgoing(paused: coordinator.isPaused, micPaused: coordinator.isMicPaused,
                                  speaking: coordinator.isOutgoingSpeaking,
                                  translating: coordinator.isOutgoingTranslating, speech: coordinator.isSpeechActive))
        set(\.incoming, .incoming(status: coordinator.incomingStatus, paused: coordinator.isPaused,
                                  speaking: coordinator.isIncomingSpeaking,
                                  translating: coordinator.isIncomingTranslating,
                                  speech: coordinator.isIncomingSpeechActive))
        set(\.title, .derive(isStarting: coordinator.isStarting, isPaused: coordinator.isPaused, incoming: incoming))
        set(\.isTranslating, coordinator.isOutgoingTranslating || coordinator.isIncomingTranslating)
        set(\.transcript, coordinator.transcript)
        set(\.sessionStartedAt, coordinator.sessionStartedAt)
        if coordinator.ttsNotice != lastTTSNotice {   // only a new TTS line is newer than the panel notice
            lastTTSNotice = coordinator.ttsNotice
            newestTransient = lastTTSNotice ?? panelNotice
        }
        if phase == .idle { clearPanelNotice() }
        routeAlert()
        set(\.notices, Self.composeNotices(listeningMode: viewModel.conversationSettings.listeningMode,
                                           transient: newestTransient))
    }

    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<CallSessionModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    nonisolated static func phase(launching: Bool, starting: Bool, active: Bool) -> SessionPhase {
        if launching { return .launching }
        if starting { return .starting }
        return active ? .running : .idle
    }

    /// The main window presents an `errorAlert` only with no session (REQ-UI-82, P14): while starting it
    /// waits for the outcome, and mid-call `routeAlert` turns it into a notice on the next main-queue turn.
    nonisolated static func mainWindowShowsAlert(isStarting: Bool, phase: SessionPhase) -> Bool {
        !isStarting && phase == .idle
    }

    /// The one place an `errorAlert` is routed (REQ-UI-36/82, P14, P27):
    /// - a running session: an 8 s notice, never a modal (mid-call, or raised by a start that went active);
    /// - no session (a start that did not go active, or a pre-call error): it stays an alert, presented
    ///   by the main window, which is brought up once per alert (e.g. after a menu-bar Start);
    /// - launching or starting: it waits for the outcome (the main window hides alerts while starting).
    private func routeAlert() {
        guard let alert = viewModel.errorAlert else { return }
        switch phase {
        case .running:
            viewModel.errorAlert = nil
            panelNotice = alert.message
            newestTransient = alert.message
            scheduleNoticeExpiry()
        case .idle:
            guard windowOpenedForAlert != alert.id else { return }
            windowOpenedForAlert = alert.id
            openMainWindow()
        case .launching, .starting:
            break
        }
    }

    private func scheduleNoticeExpiry() {
        noticeTask?.cancel()
        let (clock, duration) = (clock, noticeDuration)
        noticeTask = Task { [weak self] in
            do { try await clock.sleep(for: duration) } catch { return }
            guard !Task.isCancelled else { return }
            self?.clearPanelNotice()
            self?.recompute()
        }
    }

    private func clearPanelNotice() {
        guard panelNotice != nil else { return }
        if newestTransient == panelNotice { newestTransient = lastTTSNotice }
        panelNotice = nil
    }
}
