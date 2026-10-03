import Foundation

/// Which tier the current test plan runs. Set by the test plan's `TC_TEST_TIER` env var.
enum TestTier: String {
    case unit, integration

    static var current: TestTier {
        TestTier(rawValue: ProcessInfo.processInfo.environment["TC_TEST_TIER"] ?? "") ?? .unit
    }
}
