import Darwin
import Foundation

/// Throwaway `UserDefaults` suites for tests.
///
/// Every `UserDefaults(suiteName:)` that gets written leaves a plist in `~/Library/Preferences`, and that file
/// outlives the test run (11 000+ had piled up). Suites made here are named `TranslateCallTests.<label>.<pid>.<uuid>`:
/// each process deletes its own at exit, and on first use sweeps those of processes that are no longer running.
/// The sweep is what makes it reliable: cfprefsd writes asynchronously, so a suite written just before exit can
/// reappear after the exit pass. Runs in other checkouts at the same time keep theirs (their process is alive).
nonisolated enum ScratchDefaults {
    static let prefix = "TranslateCallTests."

    /// A fresh suite name, cleaned up as above. For tests that open the same suite twice (persistence).
    static func suiteName(_ label: String = "test") -> String {
        let name = "\(prefix)\(label).\(getpid()).\(UUID().uuidString)"
        Registry.shared.register(name)
        return name
    }

    /// A fresh, empty suite, cleaned up as above.
    static func make(_ label: String = "test") -> UserDefaults {
        UserDefaults(suiteName: suiteName(label))!
    }

    /// Deletes the suite's plist. Not `removePersistentDomain`: that leaves the file behind as `{}`. Names are
    /// unique, so cfprefsd's stale cache of a deleted suite is never read again.
    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: preferencesDirectory.appending(path: "\(name).plist"))
    }

    static var preferencesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences")
    }

    /// The pid in a suite name made by `suiteName(_:)`, if any.
    static func ownerPID(ofSuite name: String) -> pid_t? {
        guard name.hasPrefix(prefix) else { return nil }
        let parts = name.split(separator: ".")
        guard parts.count >= 4 else { return nil }
        return pid_t(parts[parts.count - 2])
    }

    fileprivate static func removeOwn() {
        Registry.shared.drain().forEach(remove)
    }

    /// Suites of processes that are no longer running (exited, crashed or killed).
    fileprivate static func sweepOrphans() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: preferencesDirectory,
                                                                        includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "plist" {
            let name = file.deletingPathExtension().lastPathComponent
            guard let pid = ownerPID(ofSuite: name), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            remove(name)
        }
    }
}

private nonisolated final class Registry: @unchecked Sendable {
    static let shared = Registry()

    private let lock = NSLock()
    private var names: Set<String> = []
    private var started = false

    func register(_ name: String) {
        lock.lock()
        let first = !started
        started = true
        names.insert(name)
        lock.unlock()
        if first {
            atexit { ScratchDefaults.removeOwn() }
            ScratchDefaults.sweepOrphans()
        }
    }

    func drain() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let drained = names
        names = []
        return drained
    }
}
