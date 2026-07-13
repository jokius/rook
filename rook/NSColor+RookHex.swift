import AppKit

extension NSColor {
    /// Rook's brand pair — the green and the graphite of the bundled `rook` theme
    /// (`rook/Resources/custom-themes/rook`, whose hexes `BundledRookThemeTests` pins). The sidebar's
    /// selected row draws its pill in these two REGARDLESS of the terminal theme, so the selection is
    /// rook chrome rather than whatever the active theme calls a selection.
    static let rookGreen = NSColor(srgbRed: 0x7E / 255.0, green: 0xCE / 255.0, blue: 0x8F / 255.0, alpha: 1)      // #7ece8f
    static let rookGraphite = NSColor(srgbRed: 0x19 / 255.0, green: 0x1C / 255.0, blue: 0x20 / 255.0, alpha: 1)   // #191c20

    /// Parse a `#RRGGBB` (or bare `RRGGBB`) hex string into an sRGB color. Returns nil for nil or
    /// malformed input, so callers can fall back to a default.
    convenience init?(rookHex hex: String?) {
        guard let hex else { return nil }
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// The color as a `#RRGGBB` sRGB hex string (alpha dropped). nil if it can't be expressed in sRGB.
    var rookHexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
