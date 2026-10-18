import Foundation
import OSLog

/// One exported log line.
nonisolated struct LogLine: Equatable, Sendable {
    let date: Date
    let category: String
    let message: String
}

/// "Export logs…" (REQ-ST-35, S-8): the app's own entries since this launch, as text.
nonisolated enum LogExporter {
    static let subsystem = "com.spbarber.TranslateCall"

    /// This process's entries of the app's subsystem. `.currentProcessIdentifier` needs no privileges.
    static func entries() throws -> [LogLine] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        return try store.getEntries(matching: predicate).compactMap { entry in
            (entry as? OSLogEntryLog).map { LogLine(date: $0.date, category: $0.category, message: $0.composedMessage) }
        }
    }

    /// `2026-10-17 20:31:02.123 [Category] message`, one line per entry, local time.
    static func text(_ lines: [LogLine], timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return lines.map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.message)" }
            .joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    /// `TranslateCall-logs-2026-10-17.txt`.
    static func fileName(on date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "TranslateCall-logs-\(formatter.string(from: date)).txt"
    }
}
