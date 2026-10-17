import Combine
import Foundation

// MARK: - MainSetupModel

/// The setup window's state: call-app choice, permissions, language packs and the resulting
/// `Readiness` (M9 UI core REQ-UI-02, 08, 30…34).
@MainActor
final class MainSetupModel: ObservableObject {
    @Published private(set) var permissions: PermissionState
    @Published private(set) var pair: PairReadiness = .checking
    @Published private(set) var readiness: Readiness
    /// The monitor's row for the persisted choice; nil = none.
    @Published private(set) var selectedRow: CallAppRow?
    /// The pair as the panel and the popover show it (they observe this model, not the manager).
    @Published private(set) var sourceLanguage: Locale.Language
    @Published private(set) var targetLanguage: Locale.Language

    let monitor: CallAppMonitor
    let setupManager: SetupManager
    let languagePairManager: LanguagePairManager
    let session: CallSessionModel
    private let isInstalled: (Locale.Language, Locale.Language) async -> Bool
    private let readPermissions: () -> PermissionState
    private var cancellables: Set<AnyCancellable> = []

    init(monitor: CallAppMonitor, setupManager: SetupManager, languagePairManager: LanguagePairManager,
         session: CallSessionModel,
         isInstalled: @escaping (Locale.Language, Locale.Language) async -> Bool = AppleTranslationService.isInstalled,
         permissions: @escaping () -> PermissionState = PermissionState.current) {
        self.monitor = monitor
        self.setupManager = setupManager
        self.languagePairManager = languagePairManager
        self.session = session
        self.isInstalled = isInstalled
        readPermissions = permissions
        let current = permissions()
        self.permissions = current
        sourceLanguage = languagePairManager.sourceLanguage
        targetLanguage = languagePairManager.targetLanguage
        readiness = Readiness.derive(permissions: current, blackHolePresent: setupManager.isBlackHolePresent,
                                     pair: .checking, app: nil, phase: session.phase)
        let changes: [ObservableObjectPublisher] = [
            monitor.objectWillChange, session.objectWillChange, languagePairManager.objectWillChange,
            setupManager.objectWillChange
        ]
        for publisher in changes {
            publisher.receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.recompute() }
                .store(in: &cancellables)
        }
        recompute()
    }

    // MARK: Actions

    func select(_ row: CallAppRow) { selectOther(bundleID: row.bundleID) }

    /// nil = "None — translate only my voice". Also keeps an "Other app…" pick in the list.
    func selectOther(bundleID: String?) {
        setupManager.selectCaptureApp(bundleID: bundleID)
        monitor.setSelected(bundleID: bundleID)
        recompute()
    }

    func open(_ row: CallAppRow) async { await monitor.open(row) }

    /// Re-reads permissions and BlackHole, and re-checks the pair per direction like `AudioCoordinator.start`.
    func refresh() async {
        permissions = readPermissions()
        setupManager.checkBlackHole()
        let source = languagePairManager.sourceLanguage
        let target = languagePairManager.targetLanguage
        let outgoing = await isInstalled(source, target)
        let incoming = await isInstalled(target, source)
        pair = PairReadiness.derive(outgoingInstalled: outgoing, incomingInstalled: incoming,
                                    unsupported: languagePairManager.pairStatus == .unsupported,
                                    sourceName: languagePairManager.displayName(for: source),
                                    targetName: languagePairManager.displayName(for: target))
        recompute()
    }

    func primaryAction() async {
        switch readiness.primary {
        case .start, .openAppAndStart: await session.start(launching: selectedRow, monitor: monitor)
        case .stop: await session.stop()
        default: break
        }
    }

    // MARK: Derivation

    /// Publishes only real changes (each source's `objectWillChange` lands here).
    private func recompute() {
        let row = setupManager.selectedCaptureBundleID.flatMap { id in monitor.rows.first { $0.bundleID == id } }
        if row != selectedRow { selectedRow = row }
        if languagePairManager.sourceLanguage != sourceLanguage { sourceLanguage = languagePairManager.sourceLanguage }
        if languagePairManager.targetLanguage != targetLanguage { targetLanguage = languagePairManager.targetLanguage }
        let derived = Readiness.derive(permissions: permissions, blackHolePresent: setupManager.isBlackHolePresent,
                                       pair: pair, app: selectedRow, phase: session.phase)
        if derived != readiness { readiness = derived }
    }
}
