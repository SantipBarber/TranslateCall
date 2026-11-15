import Darwin
import Foundation
import Testing

@Suite("ScratchDefaults")
struct ScratchDefaultsTests {

    @Test("a suite name carries this process's pid, so a later run can tell it is orphaned")
    func nameCarriesPID() {
        let name = ScratchDefaults.suiteName("ScratchDefaults")
        #expect(name.hasPrefix(ScratchDefaults.prefix + "ScratchDefaults."))
        #expect(ScratchDefaults.ownerPID(ofSuite: name) == getpid())
    }

    @Test("names that are not ours, or have no pid, are never swept")
    func foreignNames() {
        #expect(ScratchDefaults.ownerPID(ofSuite: "com.apple.finder") == nil)
        #expect(ScratchDefaults.ownerPID(ofSuite: "TranslateCallTests.Label.\(UUID().uuidString)") == nil)
        #expect(ScratchDefaults.ownerPID(ofSuite: "TranslateCallTests.Label.notapid.\(UUID().uuidString)") == nil)
    }
}
