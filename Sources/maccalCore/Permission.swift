// Permission.swift — the Calendar (TCC) access gate.
//
// Going all-EventKit means the only permission maccal needs is "Calendars" — no
// Full Disk Access, no OAuth, no network. Every command calls
// CalendarAccess.require() first.
//
// maccal disclaims TCC responsibility at startup (see reexecWithDisclaim in
// main.swift) so the grant is keyed on maccal.app, not the host terminal. On an
// interactive run the system prompt appears as "maccal"; when it can't be shown
// (piped / cron / background) we print how to bootstrap it (`maccal auth`) and
// exit instead of deadlocking.
//
// NOTE: this gate (and the thin main.swift wiring) is bound to live TCC status
// and ends in exit(), so it's intentionally outside maccalCheck's reach; the
// pure run* functions carry the tested logic.

import EventKit
import Foundation

public enum CalendarAccess {
    /// Ensure we can use the calendar; otherwise instruct and exit(2).
    /// - Parameter needsWrite: write-only grants satisfy create-only commands.
    public static func require(store: EKEventStore = EKEventStore(), needsWrite: Bool = false) {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .writeOnly where needsWrite:
            return
        case .notDetermined, .writeOnly:
            // .notDetermined → first prompt (appears as "maccal" on an interactive
            // run). .writeOnly + read needed → escalate to full access.
            if requestNow(store) { return }
            instructAndExit(reason: "maccal needs full Calendar access (read + write).")
        case .denied, .restricted:
            instructAndExit(reason: "maccal's Calendar access was denied.")
        @unknown default:
            if requestNow(store) { return }
            instructAndExit(reason: "maccal needs Calendar access.")
        }
    }

    /// Trigger the system permission prompt synchronously (CLI has no run loop).
    /// The semaphore provides the happens-before barrier for the captured var.
    private static func requestNow(_ store: EKEventStore) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var granted = false
        store.requestFullAccessToEvents { ok, _ in
            granted = ok
            sem.signal()
        }
        sem.wait()
        return granted
    }

    private static func instructAndExit(reason: String) -> Never {
        FileHandle.standardError.write(Data((
            "\(reason)\n" +
            "Run `maccal auth` once in an interactive Terminal to grant maccal its own Calendar " +
            "access (a \"maccal\" dialog appears) — no terminal-wide permission needed.\n"
        ).utf8))
        exit(2)
    }
}
