// SyncStatus.swift — a shared "last successful sync" record (timestamp + a
// one-line summary), written by BOTH the CLI (the background launchd job) and
// the menu-bar app, and read by the app's menu. This lets the menu reflect
// background syncs, not just manual "Sync now"s.

import Foundation

public enum SyncStatus {
    /// ~/Library/Application Support/maccal/last-sync — a tiny file: line 1 is
    /// the epoch seconds of the last successful sync, line 2 an optional summary.
    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("maccal/last-sync", isDirectory: false)
    }

    /// Record a successful sync (best-effort; any failure is ignored). The caller
    /// passes the time, so this stays free of hidden clock reads.
    public static func record(at date: Date, summary: String) {
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(date.timeIntervalSince1970)\n\(summary)".write(to: url, atomically: true, encoding: .utf8)
    }

    /// The last successful sync (time + summary), or nil if none is recorded.
    public static func last() -> (date: Date, summary: String)? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first, let t = TimeInterval(first.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (Date(timeIntervalSince1970: t), lines.count > 1 ? String(lines[1]) : "")
    }
}
