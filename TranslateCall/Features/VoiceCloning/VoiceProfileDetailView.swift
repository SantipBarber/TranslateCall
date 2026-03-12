import SwiftUI

struct VoiceProfileDetailView: View {
    let header: VoiceProfileHeader

    @EnvironmentObject private var profileManager: VoiceProfileManager
    @State private var editedName: String = ""
    @State private var showDeleteConfirmation = false
    @State private var isEditing = false

    private var isActive: Bool {
        profileManager.activeProfileId == header.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Name (editable)
            nameSection

            Divider()

            // Quality metrics grid
            qualityGrid

            Divider()

            // Actions
            actionButtons
        }
        .padding(24)
        .frame(minWidth: 350)
        .onAppear { editedName = header.name }
        .confirmationDialog(
            "Delete Profile",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Delete \"\(header.name)\"", role: .destructive) {
                Task { try? await profileManager.delete(id: header.id) }
            }
        } message: {
            Text("This will permanently delete the voice profile and its audio data. This cannot be undone.")
        }
    }

    // MARK: - Name section

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if isEditing {
                    TextField("Profile name", text: $editedName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename() }
                    Button("Done") { commitRename() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Text(header.name)
                        .font(.title2.bold())
                    Button {
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: 16) {
                Label(header.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(String(format: "%.1f s", header.durationSeconds), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Quality grid

    private var qualityGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quality Metrics")
                .font(.subheadline.bold())

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    metricLabel("Peak RMS")
                    Text(String(format: "%.1f dBFS", header.quality.peakRmsDbfs))
                        .font(.caption.monospacedDigit())
                }
                GridRow {
                    metricLabel("Clipping")
                    HStack(spacing: 4) {
                        Image(systemName: header.quality.hasClipping ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(header.quality.hasClipping ? .red : .green)
                            .font(.caption)
                        Text(header.quality.hasClipping ? "Detected" : "None")
                            .font(.caption)
                    }
                }
                GridRow {
                    metricLabel("Voiced Duration")
                    Text(String(format: "%.1f s", header.quality.voicedDurationSeconds))
                        .font(.caption.monospacedDigit())
                }
                GridRow {
                    metricLabel("Grade")
                    gradeBadge(header.quality.grade)
                }
            }
        }
    }

    private func metricLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 110, alignment: .leading)
    }

    private func gradeBadge(_ grade: VoiceQualityGrade) -> some View {
        Text(grade.rawValue.capitalized)
            .font(.caption.bold())
            .padding(.horizontal, 8)
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

    // MARK: - Action buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                if isActive {
                    profileManager.setActiveProfile(nil)
                } else {
                    profileManager.setActiveProfile(header.id)
                }
            } label: {
                Label(
                    isActive ? "Remove as Active" : "Set as Active",
                    systemImage: isActive ? "checkmark.circle.fill" : "checkmark.circle"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Private

    private func commitRename() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editedName = header.name
            isEditing = false
            return
        }
        isEditing = false
        Task { try? await profileManager.rename(id: header.id, newName: trimmed) }
    }
}

#Preview {
    VoiceProfileDetailView(
        header: VoiceProfileHeader(
            id: UUID(),
            name: "My Voice",
            createdAt: .now,
            durationSeconds: 28.5,
            sampleRate: 24000,
            sampleCount: 684_000,
            quality: VoiceQualityMetrics(
                peakRmsDbfs: -18.3,
                hasClipping: false,
                voicedDurationSeconds: 25.1,
                grade: .good
            ),
            formatVersion: 1
        )
    )
    .environmentObject(VoiceProfileManager())
}
