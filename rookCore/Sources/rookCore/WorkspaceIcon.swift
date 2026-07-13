import Foundation

/// A workspace's sidebar icon: an SF Symbol name, a single emoji, or an image file (SVG/PNG/JPEG) copied
/// into the state dir. Stored on `Workspace`, persisted in `WorkspaceSnapshot`, and carried on the control
/// wire. Host-free + `Codable`, modeled on `BackgroundWatermark`: the app target turns it into an `NSImage`
/// (the only step that needs AppKit) and validates an SF Symbol name, which `NSImage` alone can answer.
public struct WorkspaceIcon: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// `value` is an SF Symbol name (`hammer.fill`). Validated app-side with `NSImage(systemSymbolName:)`.
        case symbol
        /// `value` is a single emoji grapheme, rasterized to an image by the app target.
        case emoji
        /// `value` is the path of the image file copied into `WorkspaceIconStorage.directoryURL()`.
        case image
    }

    public var kind: Kind
    public var value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    /// Image formats accepted for an icon. SVG is included (and `NSImage` reads it natively, as an
    /// `_NSSVGImageRep` that scales vectorially and honors `isTemplate`), unlike the watermark's
    /// PNG/JPEG-only set — libghostty reads that one, AppKit reads this one.
    public static let supportedImageExtensions = ["svg", "png", "jpg", "jpeg"]

    public static func isSupportedImage(_ path: String) -> Bool {
        supportedImageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Whether every VISIBLE pixel of an un-premultiplied RGBA8 raster carries the SAME color — the one
    /// case where AppKit TEMPLATE rendering preserves the picture, since a template keeps only the ALPHA
    /// and repaints every visible pixel in `contentTintColor`.
    ///
    /// This is what decides whether the workspace's `colorHex` may tint an `.image` icon. It replaces the
    /// old "an SVG is a monochrome vector" assumption, which was simply false: an SVG whose background is
    /// an opaque full-bleed `<rect>` (the norm for a downloaded logo) masked to a SOLID BLOCK of the tint
    /// — the empty rectangle the sidebar drew instead of the icon — and a multi-color one flattened to a
    /// silhouette. Format has nothing to do with it; the pixels do.
    ///
    /// `alphaFloor` drops all-but-invisible pixels (antialiasing fringe, a stray 1% halo) so they cannot
    /// out-vote the picture, and `tolerance` absorbs the rounding of a single color through rasterization.
    public static func isMonochrome(rgba: [UInt8], alphaFloor: UInt8 = 26, tolerance: UInt8 = 16) -> Bool {
        var lowest: [UInt8] = [.max, .max, .max]
        var highest: [UInt8] = [.min, .min, .min]
        var sawVisiblePixel = false
        for pixel in stride(from: 0, to: rgba.count - 3, by: 4) {
            guard rgba[pixel + 3] >= alphaFloor else { continue }
            sawVisiblePixel = true
            for channel in 0..<3 {
                lowest[channel] = min(lowest[channel], rgba[pixel + channel])
                highest[channel] = max(highest[channel], rgba[pixel + channel])
            }
        }
        guard sawVisiblePixel else { return false } // nothing to tint: draw it as-is rather than mask it
        return (0..<3).allSatisfy { highest[$0] - lowest[$0] <= tolerance }
    }

    /// Exactly one emoji grapheme. The single-cluster check rejects `"🚀🚀"`, and the emoji-presentation
    /// check rejects a plain word (which must fall through to the SF Symbol branch instead) as well as a
    /// bare digit or `#`/`*`, whose scalars are technically `isEmoji` but render as text.
    public static func isValidEmoji(_ raw: String) -> Bool {
        guard raw.count == 1, let character = raw.first else { return false }
        return character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
    }

    /// Which kind a raw `workspace.icon` argument names, so the CLI, the dispatcher, and the GUI classify
    /// it identically. A path wins first (it is the only form that can contain `/` or an image extension),
    /// then a single emoji, and anything else is taken for an SF Symbol name — those are dot-separated
    /// ASCII (`hammer.fill`), so they can't collide with either.
    public static func kind(forRawIcon raw: String) -> Kind {
        if raw.contains("/") || isSupportedImage(raw) { return .image }
        if isValidEmoji(raw) { return .emoji }
        return .symbol
    }
}
