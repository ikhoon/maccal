// Confirm.swift — the write-confirmation seam + shared write-command support.
//
// A Confirmer decides whether a destructive write proceeds; injecting it keeps
// the confirm/abort branches of runAdd/runEdit/runRm testable with no terminal.
// The command layer supplies a TTY-backed confirmer or refuses on a non-TTY.

import Foundation

/// Presents a preview + question and returns whether to proceed.
public protocol Confirmer {
    func confirm(_ message: String) -> Bool
}

/// Always proceeds — used for --yes and in checks.
public struct AutoYes: Confirmer {
    public init() {}
    public func confirm(_: String) -> Bool { true }
}

/// Always declines — the safe default and used in checks for the abort path.
public struct AutoNo: Confirmer {
    public init() {}
    public func confirm(_: String) -> Bool { false }
}

/// Outcome of a write command, so the command layer routes stdout/stderr/exit.
public enum WriteResult: Equatable {
    case wrote(String)   // success — print to stdout, exit 0
    case dryRun(String)  // preview only — print to stdout, exit 0
    case aborted         // user declined — command prints "aborted" to stderr, exit 1 (nothing written)

    public var output: String {
        switch self {
        case .wrote(let s), .dryRun(let s): return s
        case .aborted: return ""
        }
    }
    public var performed: Bool {
        if case .wrote = self { return true }
        return false
    }
}

/// Resolve an optional IANA tz id against a fallback; throws on a bad id.
public func resolveTimeZone(_ id: String?, fallback: TimeZone) throws -> TimeZone {
    guard let id else { return fallback }
    guard let zone = TimeZone(identifier: id) else { throw WriteValidationError.invalidTimeZone(id) }
    return zone
}

/// busy | free | tentative | unavailable, validated.
public func validateAvailability(_ value: String) throws -> String {
    guard ["busy", "free", "tentative", "unavailable"].contains(value) else {
        throw WriteValidationError.invalidAvailability(value)
    }
    return value
}
