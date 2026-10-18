import Foundation
import Testing
@testable import TranslateCall

@MainActor
private func freshDefaults() -> UserDefaults {
    let name = "CloudPolicyTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("Cloud policy (M9 UI settings REQ-ST-15, 32)") @MainActor
struct CloudPolicyTests {

    @Test("off by default; on for an install that already consented to Edge; then stored")
    func defaultFollowsExistingConsent() {
        #expect(!CloudPolicy(defaults: freshDefaults(), edgeConsentGiven: { false }, grantEdgeConsent: {}).allowed)
        let defaults = freshDefaults()
        #expect(CloudPolicy(defaults: defaults, edgeConsentGiven: { true }, grantEdgeConsent: {}).allowed)
        #expect(defaults.object(forKey: CloudPolicy.allowedKey) as? Bool == true)

        let policy = CloudPolicy(defaults: defaults, edgeConsentGiven: { true }, grantEdgeConsent: {})
        policy.allowed = false
        #expect(!CloudPolicy(defaults: defaults, edgeConsentGiven: { true }, grantEdgeConsent: {}).allowed)
    }

    @Test("consent is per engine; only Edge is a cloud engine")
    func consent() {
        var granted = false
        let policy = CloudPolicy(defaults: freshDefaults(), edgeConsentGiven: { granted },
                                 grantEdgeConsent: { granted = true })
        #expect(!policy.hasConsent(.edgeTTS))
        policy.grantConsent(.kokoro)
        #expect(!granted)
        policy.grantConsent(.edgeTTS)
        #expect(policy.hasConsent(.edgeTTS))
        #expect(!policy.hasConsent(.avSpeech))
    }

    @Test("a cloud engine runs only when allowed, consented and available (NFR-ST-02)",
          arguments: [(true, true, false, true), (false, true, false, false),
                      (true, false, false, false), (true, true, true, false)])
    func permits(allowed: Bool, consented: Bool, unavailable: Bool, expected: Bool) {
        let snapshot = CloudSnapshot(allowed: allowed, consented: consented ? [.edgeTTS] : [],
                                     unavailable: unavailable ? [.edgeTTS] : [])
        #expect(snapshot.permits(.edgeTTS) == expected)
    }
}
