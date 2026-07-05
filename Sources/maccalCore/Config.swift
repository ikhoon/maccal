// Config.swift — CLI defaults loaded from a JSON file.
//
// Resolution (first hit wins): $MACCAL_CONFIG → $XDG_CONFIG_HOME/maccal/config.json
// → ~/.config/maccal/config.json. A missing file is not an error — you get the
// built-in defaults. Unknown keys are ignored so an older CLI tolerates a newer
// file. Every value is a *default*: an explicit CLI flag always wins over it
// (precedence: flag > env > config file > built-in), which main.swift enforces.
//
// Kept pure and dependency-free (JSONDecoder only) so maccalCheck can parse
// fixtures without touching the filesystem.

import Foundation

public struct Config: Codable, Equatable, Sendable {
    /// Calendars hidden from `calendars` and from event listings by default.
    /// Each entry matches case-insensitively against a calendar's identifier OR
    /// its title, so you can write a human name ("Birthdays") or pin a stable
    /// identifier. `--all` — or an explicit `--calendar` naming one — overrides.
    public var hiddenCalendars: [String]
    /// Default calendar for `add`/`import` when `--calendar` is omitted.
    public var defaultCalendar: String?
    /// Color mode: "auto" (color on a TTY only — the default), "always", "never".
    public var color: String?

    public init(hiddenCalendars: [String] = [], defaultCalendar: String? = nil, color: String? = nil) {
        self.hiddenCalendars = hiddenCalendars
        self.defaultCalendar = defaultCalendar
        self.color = color
    }

    // Custom decode so every key is optional: a file with only `hiddenCalendars`
    // (or an empty `{}`) still decodes, and absent keys fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hiddenCalendars = try c.decodeIfPresent([String].self, forKey: .hiddenCalendars) ?? []
        defaultCalendar = try c.decodeIfPresent(String.self, forKey: .defaultCalendar)
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }

    /// True when a calendar with this title/identifier is on the hide-list. Uses
    /// the SAME folding as `--calendar` selection and `EventInfo.matchesCalendar`
    /// (locale-aware for the title, plain for the ASCII identifier) so `calendars`
    /// and agenda/search/free agree on the hidden set on every locale.
    public func isHidden(title: String, identifier: String) -> Bool {
        hiddenCalendars.contains {
            title.localizedCaseInsensitiveCompare($0) == .orderedSame
                || identifier.caseInsensitiveCompare($0) == .orderedSame
        }
    }

    /// Resolve the color mode into an on/off decision. `isTTY` is whether stdout
    /// is a terminal; `flagNoColor` is the `--no-color` flag; `envNoColor` is
    /// whether NO_COLOR is set. `--no-color`/NO_COLOR force off regardless of the
    /// config's "always"; otherwise "always" → on, "never" → off, "auto"/nil → TTY.
    public func useColor(isTTY: Bool, flagNoColor: Bool, envNoColor: Bool) -> Bool {
        if flagNoColor || envNoColor { return false }
        switch (color ?? "auto").lowercased() {
        case "always": return true
        case "never": return false
        default: return isTTY
        }
    }
}

public enum ConfigLoader {
    /// The config path per the resolution order above.
    public static func path(
        environment env: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        if let p = env["MACCAL_CONFIG"], !p.isEmpty { return p }
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty { return "\(xdg)/maccal/config.json" }
        return "\(home)/.config/maccal/config.json"
    }

    /// Parse config JSON. Pure and testable; throws on malformed JSON.
    public static func parse(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    /// Load the config from disk. No file → built-in defaults (not an error).
    /// A present-but-malformed file throws, so the caller can warn instead of
    /// silently running with the wrong settings.
    public static func load(
        path explicit: String? = nil,
        environment env: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) throws -> Config {
        let p = explicit ?? path(environment: env, home: home)
        guard let data = FileManager.default.contents(atPath: p) else { return Config() }
        return try parse(data)
    }
}
