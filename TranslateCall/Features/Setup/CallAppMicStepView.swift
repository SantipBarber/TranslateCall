import AppKit
import SwiftUI

/// Step 3: set BlackHole 2ch as the call app's microphone (REQ-FR-30…33).
struct CallAppMicStepView: View {
    @ObservedObject var monitor: CallAppMonitor
    /// The persisted call app; nil with `hasChoice` = "None — translate only my voice".
    let selectedBundleID: String?
    /// False until the user (or this step's preselection) has picked something.
    let hasChoice: Bool
    let onSelect: (String?) -> Void
    let onOpen: (CallAppRow) -> Void

    private var selectedRow: CallAppRow? { monitor.rows.first { $0.bundleID == selectedBundleID } }
    /// "None" only once chosen: a step never visited has no selection either (REQ-FR-33).
    private var isNone: Bool { hasChoice && selectedBundleID == nil }

    private var appName: String {
        if let selectedRow { return selectedRow.appName }
        if let id = selectedBundleID {
            return monitor.runningRegularApps().first { $0.bundleID == id }?.name ?? String(localized: "your call app")
        }
        return String(localized: "your call app")
    }

    private var otherRunningApps: [(bundleID: String, name: String)] {
        monitor.runningRegularApps().filter { app in !monitor.rows.contains { $0.bundleID == app.bundleID } }
    }

    /// "Settings › Devices": the app's settings path without the final field name.
    private var settingsLocation: String {
        var parts = guide.settingsPath.components(separatedBy: " → ")
        if parts.count > 2 { parts.removeLast() }
        return parts.joined(separator: " › ")
    }

    private var guide: VideoCallApp {
        guard let id = selectedBundleID else { return .generic }
        return VideoCallApp.matching(bundleID: id, displayName: selectedRow?.title ?? appName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SetupStepHeader(
                title: String(localized: "Set BlackHole as the microphone in \(appName)"),
                subtitle: String(localized: """
                    Your call app must listen to BlackHole instead of your real microphone, \
                    so the other person hears the translation.
                    """))
            picker
            CardBox {
                VStack(spacing: 0) {
                    instruction(1) {
                        Text("In \(appName), open \(settingsLocation)")
                    }
                    Divider()
                    instruction(2) { Text("Set Microphone to"); chip("BlackHole 2ch", tint: Theme.accent) }
                    Divider()
                    instruction(3) { Text("Keep Speaker as your headphones"); chip("Not BlackHole", tint: .secondary) }
                }
            }
            footnote
        }
        .onAppear(perform: preselect)
    }

    // MARK: Picker

    private var picker: some View {
        HStack(spacing: 8) {
            Text("Call app").font(.system(size: 12)).foregroundStyle(.secondary)
            Menu {
                ForEach(monitor.rows) { row in
                    Button(row.title) { onSelect(row.bundleID) }
                }
                let others = otherRunningApps
                if !others.isEmpty {
                    Divider()
                    ForEach(others, id: \.bundleID) { app in Button(app.name) { onSelect(app.bundleID) } }
                }
                Divider()
                Button("None — translate only my voice") { onSelect(nil) }
            } label: {
                HStack(spacing: 6) {
                    pickerIcon
                    Text(pickerTitle).font(.system(size: 12, weight: .semibold))
                }
            }
            .menuStyle(.button)
            .fixedSize()
            .accessibilityLabel("Call app")
            .accessibilityValue(pickerTitle)
        }
    }

    @ViewBuilder
    private var pickerIcon: some View {
        if let path = selectedRow?.appURL?.path, FileManager.default.fileExists(atPath: path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: selectedRow?.symbol ?? (isNone ? "person.wave.2" : "app")).frame(width: 16, height: 16)
        }
    }

    private var pickerTitle: String {
        if let selectedRow { return selectedRow.title }
        if isNone { return String(localized: "None — translate only my voice") }
        return selectedBundleID == nil ? String(localized: "Choose…") : appName
    }

    // MARK: Rows

    private func instruction<Row: View>(_ number: Int, @ViewBuilder _ row: () -> Row) -> some View {
        HStack(spacing: 10) {
            Text("\(number)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22).background(Theme.soft(Theme.accent), in: Circle())
                .accessibilityHidden(true)
            row().font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number)")
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isNone {
                Label("The other side will not be translated.", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    if let row = selectedRow {
                        Button("Open \(row.appName)") { onOpen(row) }
                    }
                    Text("We'll check it works in the next step.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Preselection

    /// First time here: the first running known app, else nothing (REQ-FR-30).
    private func preselect() {
        guard !hasChoice, let first = monitor.rows.first(where: \.isRunning) else { return }
        onSelect(first.bundleID)
    }
}
