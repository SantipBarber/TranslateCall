import SwiftUI

/// One-line incoming pipeline status with Retry (F8.5.1 REQ-C-36). Renders nothing when idle/active.
struct IncomingStatusBanner: View {
    let status: IncomingStatus
    let onRetry: () -> Void

    static func text(for status: IncomingStatus) -> String? {
        switch status {
        case .idle, .active: return nil
        case .disabled: return "Incoming off — choose the call app above"
        case .starting: return "Connecting to call audio…"
        case .stopped(let reason): return "Incoming stopped: \(reason.message)"
        }
    }

    static func showsRetry(_ status: IncomingStatus) -> Bool {
        if case .stopped = status { return true }
        return false
    }

    var body: some View {
        if let text = Self.text(for: status) {
            HStack(spacing: 6) {
                Image(systemName: Self.showsRetry(status) ? "exclamationmark.triangle.fill" : "speaker.slash")
                    .foregroundStyle(Self.showsRetry(status) ? .orange : .secondary)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if Self.showsRetry(status) {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
