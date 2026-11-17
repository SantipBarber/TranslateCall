import SwiftUI

/// The four steps with their state (REQ-FR-01, 04) and the on-device note.
struct SetupSidebar: View {
    let current: SetupStep
    let statuses: [SetupStep: SetupStepStatus]
    let onSelect: (SetupStep) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Set up TranslateCall")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            ForEach(SetupStep.allCases, id: \.self) { step in
                SetupSidebarRow(step: step, status: statuses[step] ?? .todo, isCurrent: step == current) {
                    onSelect(step)
                }
            }
            Spacer()
            Label("Everything stays on this Mac", systemImage: "lock")
                .labelStyle(SidebarNoteLabelStyle())
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 12)
        .padding(.top, 48)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }
}

private struct SidebarNoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(Theme.Status.green)
            configuration.title.foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
    }
}

struct SetupSidebarRow: View {
    let step: SetupStep
    let status: SetupStepStatus
    let isCurrent: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                badge
                Text(step.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent || status == .done ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(isCurrent ? Color(.controlBackgroundColor) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.rawValue + 1). \(step.title), \(statusText)")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    private var statusText: String {
        switch status {
        case .done: String(localized: "done")
        case .attention: String(localized: "needs attention")
        case .todo: String(localized: "not done")
        }
    }

    private var badge: some View {
        ZStack {
            Circle().fill(badgeColor)
            switch status {
            case .done where !isCurrent:
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            case .attention where !isCurrent:
                Text("!").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            default:
                Text("\(step.rawValue + 1)").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isCurrent ? Color.white : Color.secondary)
            }
        }
        .frame(width: 20, height: 20)
    }

    private var badgeColor: Color {
        if isCurrent { return Theme.accent }
        switch status {
        case .done: return Theme.Status.green
        case .attention: return Theme.Status.orange
        case .todo: return Color(.quaternaryLabelColor).opacity(0.5)
        }
    }
}

/// Title and subtitle shared by the four steps (20 bold / 13 secondary).
struct SetupStepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 20, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
