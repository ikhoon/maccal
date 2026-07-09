// Contrast.swift — pick a mark colour that stays readable on a calendar's own
// fill. Kept pure and hex-based (no AppKit, no NSColor) so the rule the menu-bar
// app draws with is directly testable.

import Foundation

public enum Contrast {
    /// WCAG 2.x relative luminance of an `#RRGGBB` string, or nil when the
    /// string is not one (`CalendarInfo.color` is "" for a colourless calendar).
    public static func relativeLuminance(hex: String) -> Double? {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        func lin(_ c: Int) -> Double {
            let v = Double(c) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin((v >> 16) & 0xff) + 0.7152 * lin((v >> 8) & 0xff) + 0.0722 * lin(v & 0xff)
    }

    /// Whether a checkmark drawn on a fill of `hex` should be black rather than
    /// white.
    ///
    /// White is the conventional tick and reads well on the blues, reds, browns
    /// and purples calendars usually take, so it stays as long as it clears
    /// WCAG's 3:1 floor for non-text marks. Past that — oranges, greens,
    /// yellows, anything near white — white washes out (system orange gives only
    /// 2.2:1) and black is the readable choice. A colourless calendar never
    /// reaches a drawn box, so its answer is arbitrary.
    public static func prefersBlackMark(onFill hex: String) -> Bool {
        guard let l = relativeLuminance(hex: hex) else { return true }
        return 1.05 / (l + 0.05) < 3 // contrast ratio of white against the fill
    }
}
