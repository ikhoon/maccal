// AppVersion.swift — resolve the app's version string in a way that survives
// being launched through a symlink. `Bundle.main.infoDictionary` reads the
// Info.plist relative to the *unresolved* executable path, so when the CLI is
// invoked via a Homebrew `bin/maccal` symlink (into maccal.app/Contents/MacOS/),
// Bundle.main points at bin/ — where there is no Info.plist — and the version
// falls back to "dev". We instead resolve the real executable path and read
// <bundle>.app/Contents/Info.plist directly.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum AppVersion {
    /// CFBundleShortVersionString for the running executable, or "dev" if it
    /// can't be resolved (e.g. running the raw SwiftPM build with no bundle).
    public static var current: String {
        infoPlistVersion(forExecutable: executableURL()) ?? "dev"
    }

    /// The running executable's real path, with symlinks resolved. Falls back to
    /// Bundle.main's executableURL if the dyld lookup is unavailable.
    public static func executableURL() -> URL? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard size > 0, _NSGetExecutablePath(&buf, &size) == 0 else {
            return Bundle.main.executableURL?.resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath()
    }

    /// Read CFBundleShortVersionString from the Info.plist of the .app bundle
    /// that contains `exe` (expected at <bundle>.app/Contents/MacOS/<exe>).
    /// URL seam so it's unit-testable against a fake bundle. The build-time
    /// "dev" placeholder is treated as absent so a real value can be stamped in.
    public static func infoPlistVersion(forExecutable exe: URL?) -> String? {
        guard let exe else { return nil }
        let info = exe.deletingLastPathComponent()   // .../Contents/MacOS
            .deletingLastPathComponent()             // .../Contents
            .appendingPathComponent("Info.plist")
        guard let dict = NSDictionary(contentsOf: info),
              let v = dict["CFBundleShortVersionString"] as? String,
              !v.isEmpty, v != "dev"
        else { return nil }
        return v
    }

    /// Whether `candidate` is a strictly newer release than `current`, comparing
    /// the leading dotted numeric components left to right (missing components
    /// count as 0). A leading "v" and any git-describe / prerelease suffix
    /// ("-3-gabc123", "-beta") are ignored, so a dev build past a tag
    /// ("0.10.0-3-g…") reads as *equal* to that tag (up to date), while the next
    /// tag ("0.11.0") reads as newer. An unparseable `current` (the "dev"
    /// placeholder) is 0.0.0, so any real release counts as an update.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numericComponents(candidate), b = numericComponents(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The leading dotted numeric part of a version string as integers:
    /// "v0.11.0-3-gabc" → [0, 11, 0]. Stops at the first non-numeric component.
    private static func numericComponents(_ s: String) -> [Int] {
        let core = s.hasPrefix("v") ? String(s.dropFirst()) : s
        let base = core.prefix { $0 != "-" && $0 != "+" }   // drop git-describe / prerelease tail
        var out: [Int] = []
        for part in base.split(separator: ".") {
            guard let n = Int(part) else { break }
            out.append(n)
        }
        return out
    }
}
