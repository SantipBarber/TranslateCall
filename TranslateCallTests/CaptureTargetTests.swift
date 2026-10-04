import Foundation
import Testing
@testable import TranslateCall

@Suite("IncomingStopReason")
struct IncomingStopReasonTests {

    @Test("maps capture errors to stop reasons")
    func mapsErrors() {
        #expect(IncomingStopReason(error: SystemAudioCaptureError.targetNotFound(bundleID: "us.zoom.xos"))
                == .targetNotFound(bundleID: "us.zoom.xos"))
        #expect(IncomingStopReason(error: SystemAudioCaptureError.permissionDenied) == .permissionDenied)
        let other = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        #expect(IncomingStopReason(error: other) == .streamError("boom"))
        // Unwrapped once: the banner already says "Call audio capture failed: …".
        #expect(IncomingStopReason(error: SystemAudioCaptureError.streamFailed(underlying: other))
                == .streamError("boom"))
    }

    @Test("every reason has a non-empty user message naming the cause")
    func messages() {
        #expect(IncomingStopReason.targetNotFound(bundleID: "us.zoom.xos").message.contains("us.zoom.xos"))
        #expect(IncomingStopReason.permissionDenied.message.contains("Screen Recording"))
        #expect(IncomingStopReason.streamError("boom").message.contains("boom"))
    }
}
