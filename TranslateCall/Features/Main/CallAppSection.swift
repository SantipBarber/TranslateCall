import AppKit
import SwiftUI

/// The "Call app" list of the setup window (REQ-UI-02…04).
struct CallAppSection: View {
    @ObservedObject var monitor: CallAppMonitor
    let selectedBundleID: String?
    let onSelect: (CallAppRow) -> Void
    let onOpen: (CallAppRow) -> Void
    let onSelectOther: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader("Call app")
            CardBox {
                VStack(spacing: 0) {
                    ForEach(monitor.rows) { row in
                        CallAppRowView(row: row, isSelected: row.bundleID == selectedBundleID,
                                       onSelect: { onSelect(row) }, onOpen: { onOpen(row) })
                        Divider()
                    }
                    otherMenu
                }
            }
        }
    }

    private var otherMenu: some View {
        Menu {
            ForEach(monitor.runningRegularApps(), id: \.bundleID) { app in
                Button(app.name) { onSelectOther(app.bundleID) }
            }
            Divider()
            Button("None — translate only my voice") { onSelectOther(nil) }
        } label: {
            Label("Other app…", systemImage: "plus")
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}

/// One call app: icon, name, running state, Open, and a checkmark when chosen.
struct CallAppRowView: View {
    let row: CallAppRow
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Button(action: onSelect) {
                HStack(spacing: Theme.Spacing.medium) {
                    icon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                        statusLine
                    }
                    Spacer(minLength: Theme.Spacing.small)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !row.isRunning {
                Button("Open", action: onOpen)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(Theme.accent).fontWeight(.semibold)
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(isSelected ? Theme.soft(Theme.accent) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var icon: some View {
        if let path = row.appURL?.path, FileManager.default.fileExists(atPath: path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 24, height: 24)
        } else {
            Image(systemName: row.symbol).frame(width: 24, height: 24)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 4) {
            Circle().fill(row.isRunning ? Theme.Status.green : Theme.Status.neutral).frame(width: 6, height: 6)
            Text(row.isRunning ? "Running" : "Not open")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var accessibilityText: String {
        let state = row.isRunning ? String(localized: "running") : String(localized: "not open")
        return isSelected ? String(localized: "\(row.title), \(state), selected") : "\(row.title), \(state)"
    }
}

#if DEBUG
@MainActor
enum CallAppFixtures {
    static func monitor() -> CallAppMonitor {
        CallAppMonitor(workspace: PreviewWorkspace())
    }
}

@MainActor
private final class PreviewWorkspace: WorkspaceProviding {
    let changes = AsyncStream<Void> { _ in }
    func urlForApplication(bundleID: String) -> URL? { nil }
    func defaultBrowserURL() -> URL? { nil }
    func bundleID(ofAppAt url: URL) -> String? { nil }
    func displayName(ofAppAt url: URL) -> String { "" }
    func runningBundleIDs() -> Set<String> { [] }
    func runningRegularApps() -> [(bundleID: String, name: String)] { [] }
    func openApplication(at url: URL) async throws {}
    func open(_ url: URL) {}
}

struct CallAppSectionPreviewContent: View {
    var body: some View {
        CardBox {
            VStack(spacing: 0) {
                ForEach(Self.rows) { row in
                    CallAppRowView(row: row, isSelected: row.bundleID == "teams", onSelect: {}, onOpen: {})
                    Divider()
                }
            }
        }
        .padding()
        .frame(width: 360)
        .background(Color(.windowBackgroundColor))
    }

    static let rows: [CallAppRow] = [
        row("teams", "Microsoft Teams (work or school)", "video", true), row("zoom", "Zoom", "video", false),
        row("meet", "Google Meet · Chrome", "globe", true), row("ft", "FaceTime", "phone", false)
    ]

    private static func row(_ id: String, _ title: String, _ symbol: String, _ running: Bool) -> CallAppRow {
        CallAppRow(bundleID: id, title: title, appName: title, callAppID: id, symbol: symbol, appURL: nil,
                   openURL: nil, isRunning: running)
    }
}

#Preview("Call app — light") { CallAppSectionPreviewContent() }
#Preview("Call app — dark") { CallAppSectionPreviewContent().preferredColorScheme(.dark) }
#endif
