import SwiftUI

struct VoiceProfileListView: View {
    /// A translation session is running or starting: previews are disabled (F8.5.2 REQ-T-33).
    var isSessionActive: Bool = false

    /// Qwen language preselected for a guided recording.
    var defaultLanguage: String = "english"

    @EnvironmentObject private var profileManager: VoiceProfileManager

    @State private var showRecording = false
    @State private var deleteTarget: VoiceProfileHeader?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Voice Profiles")
                    .font(.headline)
                Spacer()
                Button {
                    showRecording = true
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()

            Divider()

            // Profile list or empty state
            if profileManager.profiles.isEmpty {
                emptyState
            } else {
                profileList
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .sheet(isPresented: $showRecording) {
            VoiceRecordingFlowView(defaultLanguage: defaultLanguage) { showRecording = false }
                .environmentObject(profileManager)
        }
        .confirmationDialog(
            "Delete Profile",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { header in
            Button("Delete \"\(header.name)\"", role: .destructive) {
                Task { try? await profileManager.delete(id: header.id) }
            }
        } message: { header in
            Text("This will permanently delete the voice profile \"\(header.name)\" and its audio data.")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No voice profiles yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Record your voice to enable voice cloning.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Record First Profile") {
                showRecording = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Spacer()
        }
        .padding()
    }

    // MARK: - Profile list

    private var profileList: some View {
        List {
            ForEach(profileManager.profiles) { header in
                NavigationLink {
                    VoiceProfileDetailView(header: header, isSessionActive: isSessionActive)
                        .environmentObject(profileManager)
                } label: {
                    profileRow(header)
                }
                .contextMenu {
                    Button("Set as Active") {
                        profileManager.setActiveProfile(header.id)
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        deleteTarget = header
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func profileRow(_ header: VoiceProfileHeader) -> some View {
        HStack(spacing: 10) {
            // Active indicator
            if profileManager.activeProfileId == header.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(header.name)
                    .font(.body)
                    .lineLimit(1)
                Text(header.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(String(format: "%.0fs", header.durationSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            gradeBadge(header.quality.grade)
        }
        .padding(.vertical, 2)
    }

    private func gradeBadge(_ grade: VoiceQualityGrade) -> some View {
        Text(grade.rawValue.capitalized)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(gradeColor(grade).opacity(0.15))
            .foregroundStyle(gradeColor(grade))
            .cornerRadius(4)
    }

    private func gradeColor(_ grade: VoiceQualityGrade) -> Color {
        switch grade {
        case .good: return .green
        case .fair: return .yellow
        case .poor: return .red
        }
    }
}

#Preview("Empty") {
    VoiceProfileListView()
        .environmentObject(VoiceProfileManager())
}
