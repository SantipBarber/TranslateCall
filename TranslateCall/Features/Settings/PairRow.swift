import SwiftUI

/// One "<mine> ↔ <theirs>" row of the pairs list in Settings › Advanced (REQ-ST-30): a real button, so
/// it works with the keyboard and VoiceOver.
struct PairRow: View {
    let title: String
    let value: String
    let isCustom: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.small) {
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: Theme.Spacing.small)
                Text(value)
                    .font(.callout)
                    .foregroundStyle(isCustom ? Theme.Status.orange : .secondary)
                    .lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
        .accessibilityAddTraits(.isButton)
    }
}
