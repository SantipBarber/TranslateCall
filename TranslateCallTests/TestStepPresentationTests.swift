import Testing
@testable import TranslateCall

@Suite("TestStepPresentation (REQ-FR-40…43, 50…55)")
struct TestStepPresentationTests {
    @Test func micLines() {
        #expect(TestStepPresentation.micLine(.idle) == "Say something")
        #expect(TestStepPresentation.micLine(.running) == "Say something")
        #expect(TestStepPresentation.micLine(.passed) == "We can hear you")
        #expect(TestStepPresentation.micLine(.failed(.microphoneOff)) == "Microphone access is off")
    }

    @Test func routeLines() {
        #expect(TestStepPresentation.routeLine(.idle) == "Test")
        #expect(TestStepPresentation.routeLine(.running) == "Testing…")
        #expect(TestStepPresentation.routeLine(.passed) == "BlackHole receives audio")
        #expect(TestStepPresentation.routeLine(.failed(.noBlackHole)) == "BlackHole 2ch not found")
    }

    @Test func incomingLine() {
        #expect(TestStepPresentation.incomingLine(appName: "Teams")
                == "Audio from Teams — checked in your first call")
    }

    @Test func rehearsalLines() {
        func lines(_ state: RehearsalState) -> [String] {
            TestStepPresentation.rehearsalLines(state, appName: "Teams", myLanguage: "Español")
        }
        #expect(lines(.unavailable("Available when no call is running")) == ["Available when no call is running"])
        #expect(lines(.ready).isEmpty)
        #expect(lines(.needsConsent).isEmpty)
        #expect(lines(.preparing) == ["Preparing…"])
        #expect(lines(.listening) == ["Say a short sentence in Español"])
        #expect(lines(.translating(said: "Hola")) == ["You said: Hola"])
        #expect(lines(.passed(said: "Hola", received: "Hallo")) == ["You said: Hola", "Teams receives: Hallo"])
        #expect(lines(.failed(.notHeard)) == ["We didn't hear you — try again, a bit louder"])
    }
}
