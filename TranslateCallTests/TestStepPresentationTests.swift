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

    @Test("the mic check restarts after a run or the consent question ended, not mid-run")
    func micRestartAfterRehearsal() {
        let restarts = TestStepPresentation.restartsMicCheck(from:to:) as (RehearsalState, RehearsalState) -> Bool
        #expect(restarts(.listening, .failed(.notHeard)))
        #expect(restarts(.translating(said: "hi"), .passed(said: "hi", received: "hola")))
        #expect(restarts(.needsConsent, .failed(.pipeline("BlackHole 2ch not found"))))   // accepted, failed at once
        #expect(restarts(.needsConsent, .ready))   // declined
        #expect(!restarts(.needsConsent, .preparing))
        #expect(!restarts(.preparing, .listening))
        #expect(!restarts(.ready, .needsConsent))
        #expect(!restarts(.ready, .unavailable("Available when no call is running")))
    }

    @Test("the mic check restarts when a call ended, not after a rehearsal's session")
    func micRestartAfterCall() {
        let restarts = TestStepPresentation.restartsMicCheck(from:to:) as (SessionPhase, SessionPhase) -> Bool
        #expect(restarts(.running, .idle))
        #expect(restarts(.starting, .idle))
        #expect(restarts(.launching, .idle))
        #expect(!restarts(.rehearsing, .idle))
        #expect(!restarts(.idle, .running))
    }
}
