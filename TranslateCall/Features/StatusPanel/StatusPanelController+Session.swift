import Combine
import Foundation

extension StatusPanelController {
    /// Shows the panel while the session runs and "Show the status panel" is on, and hides it when the
    /// session ends or the setting is turned off mid-call (REQ-UI-40/47, P25). Only changes act: a
    /// re-emitted `.running` does not re-order the panel front. Stop never reopens the main window.
    func bind(to session: CallSessionModel, defaults: UserDefaults = .standard) {
        let showSetting = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: DispatchQueue.main)   // read the setting on the main actor, whoever wrote it
            .map { _ in () }
            .prepend(())
            .map { defaults.bool(forKey: UISettingsKeys.showStatusPanel) }
            .removeDuplicates()
        sessionSubscription = session.$phase.removeDuplicates()
            .combineLatest(showSetting)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase, show in
                switch phase {
                case .running: if show { self?.show() } else { self?.hide() }
                case .idle: self?.hide()
                case .launching, .starting: break
                }
            }
    }
}
