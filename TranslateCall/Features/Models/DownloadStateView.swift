import SwiftUI

/// The trailing control of a model row: Download, a spinner with Cancel, or Try again (REQ-ST-14, S-4, S-7).
/// Progress is indeterminate everywhere, so a spinner stands in for a bar.
struct DownloadStateView: View {
    let state: DownloadState
    /// The unlocalized figure, e.g. "≈800 MB" (parked).
    let size: String
    /// A call is running: downloads wait until it ends (S-7).
    let blocked: Bool
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        switch state {
        case .ready:
            EmptyView()
        case .notOnDisk:
            VStack(alignment: .trailing, spacing: 2) {
                Button(action: onDownload) {
                    Text("Download · \(Text(verbatim: size))").lineLimit(1).truncationMode(.tail)
                }
                .controlSize(.small)
                .disabled(blocked)
                if blocked {
                    Text("Available after the call").font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .downloading:
            HStack(spacing: Theme.Spacing.small) {
                ProgressView().controlSize(.small)
                Button("Cancel", action: onCancel).buttonStyle(.link).font(.callout)
            }
        case .failed:
            HStack(spacing: Theme.Spacing.small) {
                Text("Download failed").font(.caption).foregroundStyle(Theme.Status.red).lineLimit(1)
                Button("Try again", action: onRetry).controlSize(.small).disabled(blocked)
            }
        }
    }
}
