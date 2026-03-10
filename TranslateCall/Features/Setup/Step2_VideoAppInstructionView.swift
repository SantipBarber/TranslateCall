import SwiftUI

struct VideoAppInstructionStepView: View {
    let app: VideoCallApp

    // When generic, let the user pick a known app to preview its instructions
    @State private var selectedApp: VideoCallApp = .generic

    private var displayedApp: VideoCallApp {
        app == .generic ? selectedApp : app
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: displayedApp.sfSymbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayedApp.displayName)
                        .font(.headline)
                    Text("Configure Microphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // If no app detected, show a picker so the user can see their app's instructions
            if app == .generic {
                Picker("Show instructions for:", selection: $selectedApp) {
                    ForEach(VideoCallApp.allCases.filter { $0 != .generic }) { knownApp in
                        Text(knownApp.displayName).tag(knownApp)
                    }
                    Text("Other").tag(VideoCallApp.generic)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Divider()

            // Steps
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(displayedApp.microphoneSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1).")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                                .frame(minWidth: 20, alignment: .trailing)
                            Text(step)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Text("Estimated time: \(displayedApp.estimatedMinutes) minute\(displayedApp.estimatedMinutes == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Previews

#Preview("Zoom") {
    VideoAppInstructionStepView(app: .zoom)
        .padding()
        .frame(width: 430, height: 300)
}

#Preview("Generic (no detected app)") {
    VideoAppInstructionStepView(app: .generic)
        .padding()
        .frame(width: 430, height: 300)
}
