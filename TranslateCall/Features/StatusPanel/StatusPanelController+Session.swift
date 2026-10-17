import Combine
import Foundation

extension StatusPanelController {
    /// Shows the panel while the session runs (and "Show the status panel" is on) and hides it when
    /// the session ends (REQ-UI-40/47, P25). Stop never reopens the main window.
    func bind(to session: CallSessionModel, defaults: UserDefaults = .standard) {
        sessionSubscription = session.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                switch phase {
                case .running where defaults.bool(forKey: UISettingsKeys.showStatusPanel): self?.show()
                case .idle: self?.hide()
                default: break
                }
            }
    }
}
