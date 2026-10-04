// SAFETY: the converter invokes its input block synchronously on the calling thread, never concurrently.
/// Mutable box for state shared with an `AVAudioConverterInputBlock`.
nonisolated final class SyncBox<T>: @unchecked Sendable {
    // SAFETY: see the class comment — only touched from one synchronous call at a time.
    nonisolated(unsafe) var value: T
    init(_ value: T) { self.value = value }
}
