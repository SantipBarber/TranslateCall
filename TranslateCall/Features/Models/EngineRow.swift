import SwiftUI

/// A small rounded label of the chip line.
private struct EngineChip: View {
    let text: Text
    let tint: Color

    var body: some View {
        text.font(.caption2).lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(Theme.soft(tint), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }
}

/// One engine of the models sheet: a selection indicator, the name, the chip line, a note and the
/// download control. In EN ↔ ES two speech rows can be selected at once (one per direction), so each
/// row draws its own indicator instead of forming a radio group.
struct EngineRow: View {
    let row: EngineRowState
    /// "ES · DE" for the "Tested" chip, in the title's order.
    var testedLabel = ""
    let blocked: Bool
    let onPick: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void

    private var isDisabled: Bool { row.availability == .notForPair || row.availability == .unavailable }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Button(action: onPick) {
                HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                    Image(systemName: row.isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(row.isSelected && !isDisabled ? Theme.accent : Color.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: row.name).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                        chipLine
                        if let note { Text(note).font(.caption).foregroundStyle(noteColor) }
                    }
                    Spacer(minLength: Theme.Spacing.small)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel(Text(verbatim: row.name))
            .accessibilityAddTraits(row.isSelected ? .isSelected : [])
            if let state = row.download {
                DownloadStateView(state: state, size: row.engine.downloadable?.approximateSize ?? "",
                                  blocked: blocked, onDownload: onPick, onCancel: onCancel, onRetry: onRetry)
            }
        }
        .padding(.vertical, Theme.Spacing.small)
        .foregroundStyle(isDisabled ? .secondary : .primary)
    }

    // MARK: Chips

    private var chipLine: some View {
        HStack(spacing: 4) {
            switch row.recommendation {
            case .none: EmptyView()
            case .both: EngineChip(text: Text("Recommended"), tint: Theme.accent)
            case .only(let language): EngineChip(text: Text("Recommended for \(language)"), tint: Theme.accent)
            }
            if row.isCloud {
                EngineChip(text: Text("Cloud"), tint: Theme.Status.orange)
            } else {
                EngineChip(text: Text("On-device"), tint: Theme.Status.green)
            }
            if row.tested { EngineChip(text: Text("Tested \(testedLabel)"), tint: Theme.Status.neutral) }
            if let latency = row.latency {
                Text(verbatim: latency).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    // MARK: Note

    private var note: LocalizedStringKey? {
        switch row.availability {
        case .partial(let language): "Used for \(language) only."
        case .notForPair: "Not available for this pair."
        case .unavailable: "Temporarily unavailable."
        case .selectable:
            row.needsConsent
                ? "The translated text is sent to Microsoft to create the voice. You'll be asked to confirm."
                : nil
        }
    }

    private var noteColor: Color {
        row.needsConsent && row.availability == .selectable ? Theme.Status.orange : .secondary
    }
}
