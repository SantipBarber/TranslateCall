import SwiftUI

struct VoiceProfileListView: View {
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
            recordingFlowSheet
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
                    VoiceProfileDetailView(header: header)
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

    // MARK: - Recording flow sheet

    private var recordingFlowSheet: some View {
        NavigationStack {
            recordingFlowContent
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            profileManager.discardAndReRecord()
                            showRecording = false
                        }
                    }
                }
        }
        .frame(minWidth: 420, minHeight: 380)
    }

    @ViewBuilder
    private var recordingFlowContent: some View {
        switch profileManager.recordingState {
        case .idle:
            recordingIdleView
        case .recording:
            VoiceRecordingView()
                .environmentObject(profileManager)
        case .processing:
            VStack(spacing: 12) {
                ProgressView("Analyzing recording...")
                    .padding()
            }
        case .reviewing(let result):
            VoiceTranscriptView(result: result)
                .environmentObject(profileManager)
                .onChange(of: profileManager.recordingState.isIdle) { _, isIdle in
                    if isIdle { showRecording = false }
                }
        case .saving:
            VStack(spacing: 12) {
                ProgressView("Saving profile...")
                    .padding()
            }
        case .error(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    profileManager.discardAndReRecord()
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
    }

    private var recordingIdleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Record Your Voice")
                .font(.headline)

            Text("Speak clearly for 10-30 seconds in a quiet room.\nThis recording will be used for voice cloning.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Start Recording") {
                Task { await profileManager.startRecording() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
    }
}

#Preview("Empty") {
    VoiceProfileListView()
        .environmentObject(VoiceProfileManager())
}
