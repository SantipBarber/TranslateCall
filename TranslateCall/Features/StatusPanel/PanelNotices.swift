import SwiftUI

/// The lines under the direction rows (REQ-UI-45): the speakers line (info) and transient notices
/// such as a skipped sentence (orange). Text wraps.
struct PanelNotices: View {
    let notices: [String]

    var body: some View {
        if !notices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                    HStack(alignment: .top, spacing: Theme.Spacing.small) {
                        Image(systemName: Self.isSpeakersLine(notice) ? "info.circle" : "forward.end")
                            .foregroundStyle(Self.isSpeakersLine(notice) ? Color.secondary : Theme.Status.orange)
                            .frame(width: 16)
                        Text(notice)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    /// The standing line is always the first one `CallSessionModel.composeNotices` produces.
    private static func isSpeakersLine(_ notice: String) -> Bool {
        notice == CallSessionModel.composeNotices(listeningMode: .speakers, transient: nil).first
    }
}
