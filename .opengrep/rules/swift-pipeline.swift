func handle(text: String) {
    // ruleid: no-capture-suppression
    guard !text.isEmpty, !outgoingCaptureSuppressed else { return }
    // ruleid: no-capture-suppression
    let manager = HalfDuplexManager(coordinator: self)
    // ruleid: no-capture-suppression
    coordinator.suppressIncomingPipeline(true)
    // ruleid: no-capture-suppression
    weak var halfDuplex: (any HalfDuplexCoordinating)?
    // ruleid: no-capture-suppression
    halfDuplex?.suppressOutgoingCapture(true)
    // ok: no-capture-suppression
    coordinator.suppressNextOutgoingTurn()
    // ok: no-capture-suppression
    micEchoGate?.setIncomingSpeaking(true)
}
