func streams() {
    var cont: AsyncStream<Int>.Continuation?
    // ruleid: asyncstream-unbounded
    let a = AsyncStream<Int> { cont = $0 }
    // ok: asyncstream-unbounded
    let b = AsyncStream<Int>(bufferingPolicy: .bufferingNewest(8)) { cont = $0 }
    // ruleid: asyncstream-force-unwrap
    let c = cont!
    // ok: asyncstream-force-unwrap
    let (s, k) = AsyncStream.makeStream(of: Int.self)
}

final class Box {
    // ruleid: nonisolated-unsafe-justified
    nonisolated(unsafe) var x = 0
    // SAFETY: only touched on the audio render thread
    // ok: nonisolated-unsafe-justified
    nonisolated(unsafe) var y = 0
}
