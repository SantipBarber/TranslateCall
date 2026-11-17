import AppKit
import SwiftUI

/// The shell of the assistant window: sidebar, the current step's content and the footer
/// (REQ-FR-01, 04). Pure inputs, so it renders from fixtures.
struct SetupAssistantLayout<Content: View>: View {
    static var windowSize: CGSize { CGSize(width: 680, height: 480) }

    let step: SetupStep
    let statuses: [SetupStep: SetupStepStatus]
    let onSelect: (SetupStep) -> Void
    let onBack: () -> Void
    let onPrimary: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            SetupSidebar(current: step, statuses: statuses, onSelect: onSelect)
                .frame(width: 210)
            VStack(spacing: 0) {
                content
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                footer
            }
            .background(Color(.windowBackgroundColor))
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    }

    private var footer: some View {
        HStack {
            if step != .permissions {
                Button("Back", action: onBack).controlSize(.large)
            }
            Spacer()
            Button(primaryTitle, action: onPrimary)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private var primaryTitle: String {
        switch step {
        case .callAppMic: String(localized: "I've done it")
        case .test: String(localized: "Finish")
        default: String(localized: "Continue")
        }
    }
}

/// The assistant window (REQ-FR-01…05, 13). Step 4 is `TestStepView`; its sidebar state comes from
/// the checks, and also counts as done once the rehearsal passed.
struct SetupAssistantView: View {
    @EnvironmentObject private var setupManager: SetupManager
    @EnvironmentObject private var model: MainSetupModel
    @Environment(\.dismissWindow) private var dismissWindow
    @EnvironmentObject private var checks: SetupChecks
    @EnvironmentObject private var rehearsal: Rehearsal
    var requester: any PermissionRequesting = PermissionRequester()
    @State private var permissions = PermissionState.current()
    @State private var screenRecordingRequested = false

    var body: some View {
        SetupAssistantLayout(
            step: setupManager.currentStep, statuses: statuses, onSelect: { setupManager.currentStep = $0 },
            onBack: back, onPrimary: primary, content: { stepContent }
        )
        .onAppear(perform: refresh)
        .onDisappear(perform: stopTest)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch setupManager.currentStep {
        case .permissions:
            PermissionsStepView(permissions: permissions, canReopen: screenRecordingRequested,
                                onAllowMicrophone: allowMicrophone, onAllowScreenRecording: allowScreenRecording,
                                onReopen: requester.relaunch)
        case .audioDriver:
            AudioDriverStepView(isPresent: setupManager.isBlackHolePresent,
                                hasOtherBlackHole: setupManager.hasOtherBlackHole,
                                onDownload: { NSWorkspace.shared.open(AudioDriverStepView.downloadURL) },
                                onCheckAgain: refresh)
        case .callAppMic:
            CallAppMicStepView(monitor: model.monitor, selectedBundleID: setupManager.selectedCaptureBundleID,
                               hasChoice: setupManager.hasCallAppChoice,
                               onSelect: model.selectOther(bundleID:),
                               onOpen: { row in Task { await model.open(row) } })
        case .test:
            TestStepView(checks: checks, rehearsal: rehearsal)
        }
    }

    private var statuses: [SetupStep: SetupStepStatus] {
        Dictionary(uniqueKeysWithValues: SetupStep.allCases.map { step in
            (step, step.status(permissions: permissions, blackHolePresent: setupManager.isBlackHolePresent,
                               hasOtherBlackHole: setupManager.hasOtherBlackHole,
                               callAppMicConfirmed: setupManager.callAppMicConfirmed, testResult: testStatus))
        })
    }

    private var testStatus: SetupStepStatus {
        if case .passed = rehearsal.state { return .done }
        return checks.testStatus
    }

    /// Closing the window or finishing stops the mic, the listeners and any rehearsal (REQ-FR-57).
    private func stopTest() {
        checks.cancelAll()
        let rehearsal = rehearsal
        Task { await rehearsal.cancel() }
    }

    private func refresh() {
        permissions = PermissionState.current()
        setupManager.checkBlackHole()
    }

    private func back() {
        move(by: -1)
    }

    private func primary() {
        switch setupManager.currentStep {
        case .callAppMic:
            setupManager.confirmCallAppMic()
            move(by: 1)
        case .test:
            setupManager.completeSetup()
            stopTest()
            dismissWindow(id: SetupWindowOpener.windowID)
        default:
            move(by: 1)
        }
    }

    private func move(by delta: Int) {
        guard let next = SetupStep(rawValue: setupManager.currentStep.rawValue + delta) else { return }
        setupManager.currentStep = next
    }

    private func allowMicrophone() {
        if permissions.microphone == .notDetermined {
            Task {
                _ = await requester.requestMicrophone()
                refresh()
            }
        } else {
            requester.openPrivacyPane(.microphone)
        }
    }

    private func allowScreenRecording() {
        if screenRecordingRequested {
            requester.openPrivacyPane(.screenRecording)
        } else {
            screenRecordingRequested = true
            requester.requestScreenRecording()
            refresh()
        }
    }
}
