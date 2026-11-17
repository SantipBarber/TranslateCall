import Foundation
import Testing
@testable import TranslateCall

@Suite("SetupStep (REQ-FR-01, 32/33)")
struct SetupStepTests {

    // MARK: - Titles

    @Test("Titles match the prototype sidebar")
    func titles() {
        #expect(SetupStep.permissions.title == "Permissions")
        #expect(SetupStep.audioDriver.title == "Audio driver")
        #expect(SetupStep.callAppMic.title == "Call app microphone")
        #expect(SetupStep.test.title == "Test")
    }

    @Test("All four steps in sidebar order; unknown raw value is nil")
    func allCasesInOrder() {
        #expect(SetupStep.allCases == [.permissions, .audioDriver, .callAppMic, .test])
        #expect(SetupStep(rawValue: 9) == nil)
    }

    // MARK: - Status rules

    @Test("Permissions done when both are granted")
    func permissionsDone() {
        let step = SetupStep.permissions
        #expect(step.status(permissions: .allGranted, blackHolePresent: false, hasOtherBlackHole: false,
                            callAppMicConfirmed: false, testResult: .todo) == .done)
    }

    @Test("Permissions todo when the microphone is missing")
    func permissionsTodoWithoutMic() {
        let step = SetupStep.permissions
        let state = PermissionState(microphone: .denied, screenRecording: .granted)
        #expect(step.status(permissions: state, blackHolePresent: false, hasOtherBlackHole: false,
                            callAppMicConfirmed: false, testResult: .todo) == .todo)
    }

    @Test("Permissions todo when screen recording is missing")
    func permissionsTodoWithoutScreenRecording() {
        let step = SetupStep.permissions
        let state = PermissionState(microphone: .granted, screenRecording: .denied)
        #expect(step.status(permissions: state, blackHolePresent: false, hasOtherBlackHole: false,
                            callAppMicConfirmed: false, testResult: .todo) == .todo)
    }

    @Test("Permissions todo when nothing is granted")
    func permissionsTodoWithoutEither() {
        let step = SetupStep.permissions
        let state = PermissionState(microphone: .notDetermined, screenRecording: .denied)
        #expect(step.status(permissions: state, blackHolePresent: false, hasOtherBlackHole: false,
                            callAppMicConfirmed: false, testResult: .todo) == .todo)
    }

    @Test("Audio driver done when BlackHole 2ch is present")
    func driverDone() {
        let step = SetupStep.audioDriver
        #expect(step.status(permissions: .allGranted, blackHolePresent: true, hasOtherBlackHole: false,
                            callAppMicConfirmed: false, testResult: .todo) == .done)
    }

    @Test("Audio driver attention with only another BlackHole channel count")
    func driverAttentionForSixteen() {
        let step = SetupStep.audioDriver
        #expect(step.status(permissions: .allGranted, blackHolePresent: false, hasOtherBlackHole: true,
                            callAppMicConfirmed: false, testResult: .todo) == .attention)
    }

    @Test("Audio driver todo with no BlackHole at all")
    func driverTodo() {
        let step = SetupStep.audioDriver
        #expect(step.status(permissions: .allGranted, blackHolePresent: false, hasOtherBlackHole: false,
                            callAppMicConfirmed: false, testResult: .todo) == .todo)
    }

    @Test("Call app microphone done once confirmed")
    func callAppMicDone() {
        let step = SetupStep.callAppMic
        #expect(step.status(permissions: .allGranted, blackHolePresent: true, hasOtherBlackHole: false,
                            callAppMicConfirmed: true, testResult: .todo) == .done)
    }

    @Test("Call app microphone todo until confirmed")
    func callAppMicTodo() {
        let step = SetupStep.callAppMic
        #expect(step.status(permissions: .allGranted, blackHolePresent: true, hasOtherBlackHole: false,
                            callAppMicConfirmed: false, testResult: .todo) == .todo)
    }

    @Test("Test passes its result through")
    func testPassesThrough() {
        let step = SetupStep.test
        #expect(step.status(permissions: .allGranted, blackHolePresent: true, hasOtherBlackHole: false,
                            callAppMicConfirmed: true, testResult: .todo) == .todo)
        #expect(step.status(permissions: .allGranted, blackHolePresent: true, hasOtherBlackHole: false,
                            callAppMicConfirmed: true, testResult: .done) == .done)
        #expect(step.status(permissions: .allGranted, blackHolePresent: true, hasOtherBlackHole: false,
                            callAppMicConfirmed: true, testResult: .attention) == .attention)
    }
}
