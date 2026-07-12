import agtermCore
import AppKit

/// Turns a `WorkspaceIcon` into the `NSImage` a sidebar row draws — the one step of the icon feature that
/// needs AppKit (the spec, its validation, and the file copy are all host-free in `agtermCore`).
///
/// Memoized by spec: a row render happens per reload, and decoding an SVG/PNG or rasterizing an emoji on
/// every pass would be wasteful. The cache is keyed on the whole spec, and `WorkspaceIconStorage.install`
/// gives every installed file a FRESH name, so replacing a workspace's image yields a different key and the
/// stale entry is never served.
@MainActor
enum WorkspaceIconImage {
    /// Matches the sidebar's other row glyphs (`WorkspaceSidebar.rowIcon`).
    private static let pointSize: CGFloat = 13
    private static let size = NSSize(width: 16, height: 16)

    private static var cache: [WorkspaceIcon: NSImage] = [:]

    /// The image for `icon`, or nil to fall back to the caller's default glyph — which is also what an
    /// unresolvable symbol, a missing file, or an undecodable image yields, so a broken icon degrades to
    /// the default workspace glyph instead of an empty row.
    static func image(for icon: WorkspaceIcon?) -> NSImage? {
        guard let icon else { return nil }
        if let cached = cache[icon] { return cached }
        guard let image = render(icon) else { return nil }
        cache[icon] = image
        return image
    }

    private static func render(_ icon: WorkspaceIcon) -> NSImage? {
        switch icon.kind {
        case .symbol:
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            let image = NSImage(systemSymbolName: icon.value, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            return image
        case .image:
            guard let image = NSImage(contentsOf: URL(fileURLWithPath: icon.value)) else { return nil }
            image.size = size
            // an SVG is a monochrome vector: as a template it takes the workspace's tint like a symbol.
            // a raster keeps its own colors — tinting it would paint over the picture.
            image.isTemplate = icon.isTintable
            return image
        case .emoji:
            return rasterize(emoji: icon.value)
        }
    }

    /// A color emoji has no `NSImage` form, so draw the grapheme into one. Never a template — the glyph
    /// carries its own colors (which is why `WorkspaceIcon.isTintable` is false for it).
    private static func rasterize(emoji: String) -> NSImage? {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: pointSize)]
        let string = NSAttributedString(string: emoji, attributes: attributes)
        let image = NSImage(size: size, flipped: false) { rect in
            let bounds = string.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin])
            let origin = NSPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2)
            string.draw(at: origin)
            return true
        }
        image.isTemplate = false
        return image
    }
}
