import SwiftUI

// MARK: - SetupWizardView

struct SetupWizardView: View {
    @ObservedObject var setupManager: SetupManager
    @Binding var isPresented: Bool

    @State private var currentStep: SetupStep = .blackHoleCheck
    @StateObject private var routeTestService = RouteTestService()

    // MARK: - Step enum

    enum SetupStep: Int, CaseIterable {
        case blackHoleCheck       = 1
        case videoAppInstructions = 2
        case captureAppSelect     = 3
        case routeTest            = 4
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            SetupProgressView(current: currentStep.rawValue, total: 4)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()

            // Step content
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)

            Divider()

            // Navigation footer
            navigationFooter
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        .frame(width: 480, height: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Dismiss") { isPresented = false }
            }
        }
        .task { await setupManager.loadCaptureApps() }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .blackHoleCheck:
            BlackHoleCheckStepView(setupManager: setupManager)
        case .videoAppInstructions:
            VideoAppInstructionStepView(app: setupManager.detectedVideoCallApp)
        case .captureAppSelect:
            CaptureAppSelectStepView(setupManager: setupManager)
        case .routeTest:
            RouteTestStepView(setupManager: setupManager, routeTestService: routeTestService)
        }
    }

    // MARK: - Navigation footer

    private var navigationFooter: some View {
        HStack {
            Button("Back") {
                if let prev = SetupStep(rawValue: currentStep.rawValue - 1) {
                    currentStep = prev
                }
            }
            .disabled(currentStep == .blackHoleCheck)

            Spacer()

            Text("Step \(currentStep.rawValue) of 4")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if currentStep == .routeTest {
                Button("Complete Setup") {
                    setupManager.completeSetup()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Next") {
                    if let next = SetupStep(rawValue: currentStep.rawValue + 1) {
                        currentStep = next
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Progress view

private struct SetupProgressView: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...total, id: \.self) { step in
                Capsule()
                    .fill(step <= current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(height: 4)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var isPresented = true
    SetupWizardView(setupManager: SetupManager(), isPresented: $isPresented)
}
