// SyncAgent.swift — spec for running `maccal sync … --yes` as a scheduled job.
//
// Pure: builds the argv and the launchd job dictionary from sync settings.
// Writing the plist file and (un)loading it via launchctl lives in the maccalbar
// menu-bar app; the argv/interval logic is kept here (no AppKit) so maccalCheck
// unit-tests it.

import Foundation

public enum SyncAgent {
    /// launchd Label and plist filename stem for the periodic sync job.
    public static let label = "kr.ikhoon.maccal-sync"

    /// The `maccal sync … --yes` command line for the given settings —
    /// `[maccal, sync, (--from S)…, --to T, (--no-location|--notes)…, --yes]`.
    /// Detail is an OptionSet, so each field maps to its own flag (location off →
    /// --no-location; notes on → --notes).
    public static func argv(maccalPath: String, sources: [String], target: String, detail: SyncDetail) -> [String] {
        var a = [maccalPath, "sync"]
        for s in sources { a += ["--from", s] }
        a += ["--to", target]
        if !detail.contains(.location) { a.append("--no-location") }
        if detail.contains(.notes) { a.append("--notes") }
        a.append("--yes")
        return a
    }

    /// launchd job dictionary: run argv every `intervalMinutes` (and once at load).
    /// `PropertyListSerialization` turns this into the `.plist` the app writes.
    public static func launchdPlist(
        maccalPath: String, sources: [String], target: String,
        detail: SyncDetail, intervalMinutes: Int
    ) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": argv(maccalPath: maccalPath, sources: sources, target: target, detail: detail),
            "StartInterval": max(1, intervalMinutes) * 60,
            "RunAtLoad": true,
            "ProcessType": "Background",
        ]
    }
}
