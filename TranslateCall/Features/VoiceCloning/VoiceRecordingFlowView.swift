import SwiftUI

/// The "new voice" sheet: choice, guided setup or free start, recording, review and save.
/// `makeActive` (the long-voice hint's "Record short sample") reaches `saveProfile(makeActive:)`
/// through the review screen; `startsGuided` skips the choice.
struct VoiceRecordingFlowView: View {
    let defaultLanguage: String
    var makeActive = false
    let onClose: () -> Void

    @EnvironmentObject private var profileManager: VoiceProfileManager

    private enum Stage { case choice, guidedSetup, free }

    @State private var stage: Stage
    @State private var language: String

    init(defaultLanguage: String, makeActive: Bool = false, startsGuided: Bool = false,
         onClose: @escaping () -> Void) {
        self.defaultLanguage = defaultLanguage
        self.makeActive = makeActive
        self.onClose = onClose
        _stage = State(initialValue: startsGuided ? .guidedSetup : .choice)
        _language = State(initialValue: defaultLanguage)
    }

    /// The Qwen language of the language the user speaks, English when it is not supported.
    static func defaultLanguage(for source: Locale.Language) -> String {
        QwenCloneConfiguration.language(for: Locale(identifier: source.minimalIdentifier)) ?? "english"
    }

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            profileManager.discardAndReRecord()
                            onClose()
                        }
                    }
                }
        }
        .frame(minWidth: 420, minHeight: 380)
        .onChange(of: profileManager.completedSaves) { onClose() }
    }

    @ViewBuilder
    private var content: some View {
        switch profileManager.recordingState {
        case .idle:
            idleContent
        case .recording:
            VoiceRecordingView()
                .environmentObject(profileManager)
        case .processing:
            ProgressView("Analyzing recording...").padding()
        case .reviewing(let result):
            VoiceTranscriptView(result: result, makeActive: makeActive)
                .environmentObject(profileManager)
        case .saving:
            ProgressView("Saving profile...").padding()
        case .error(let message):
            errorContent(message)
        }
    }

    @ViewBuilder
    private var idleContent: some View {
        switch stage {
        case .choice:
            GuidedRecordingChoiceView(onGuided: { stage = .guidedSetup }, onFree: { stage = .free })
        case .guidedSetup:
            GuidedReadingSetupView(language: $language) {
                Task { await profileManager.startRecording(mode: .guided(language: language)) }
            }
        case .free:
            freeIdleView
        }
    }

    private func errorContent(_ message: String) -> some View {
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

    private var freeIdleView: some View {
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
                Task { await profileManager.startRecording(mode: .free) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
    }
}
