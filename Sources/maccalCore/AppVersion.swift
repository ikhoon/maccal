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
}
