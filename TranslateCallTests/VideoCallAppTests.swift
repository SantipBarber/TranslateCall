import Testing
@testable import TranslateCall

@Suite("VideoCallApp")
@MainActor
struct VideoCallAppTests {

    @Test("Zoom matched by bundle ID")
    func zoomMatchesByBundleID() {
        #expect(VideoCallApp.matching(bundleID: "us.zoom.xos", displayName: "Zoom") == .zoom)
    }

    @Test("Teams matched by bundle ID")
    func teamsMatchesByBundleID() {
        #expect(VideoCallApp.matching(bundleID: "com.microsoft.teams2", displayName: "Teams") == .teams)
    }

    @Test("Meet matched by display name when bundle ID is empty")
    func meetMatchesByDisplayName() {
        #expect(VideoCallApp.matching(bundleID: "", displayName: "Meet") == .meet)
    }

    @Test("Discord matched by bundle ID")
    func discordMatchesByBundleID() {
        #expect(VideoCallApp.matching(bundleID: "com.discord", displayName: "Discord") == .discord)
    }

    @Test("Unknown app returns generic")
    func unknownAppReturnsGeneric() {
        #expect(VideoCallApp.matching(bundleID: "com.unknown.app", displayName: "SomeApp") == .generic)
    }

    @Test("All known apps have non-empty microphoneSteps")
    func allKnownAppsHaveSteps() {
        let result = VideoCallApp.allCases
            .filter { $0 != .generic }
            .allSatisfy { !$0.microphoneSteps.isEmpty }
        #expect(result)
    }

    @Test("All apps have non-empty sfSymbol")
    func allAppsHaveSFSymbol() {
        let result = VideoCallApp.allCases.allSatisfy { !$0.sfSymbol.isEmpty }
        #expect(result)
    }
}
