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

    /// Whether the workspace's `colorHex` applies to this icon.
    ///
    /// A symbol and an SVG are monochrome vectors — they load as TEMPLATE images, so `contentTintColor`
    /// recolors them. A raster image (PNG/JPEG) and a color emoji carry their own colors: tinting them
    /// would paint over the picture, so the color is deliberately ignored there.
    public var isTintable: Bool {
        switch kind {
        case .symbol: true
        case .emoji: false
        case .image: WorkspaceIcon.isVectorImage(value)
        }
    }

    /// Image formats accepted for an icon. SVG is included (and `NSImage` reads it natively, as an
    /// `_NSSVGImageRep` that scales vectorially and honors `isTemplate`), unlike the watermark's
    /// PNG/JPEG-only set — libghostty reads that one, AppKit reads this one.
    public static let supportedImageExtensions = ["svg", "png", "jpg", "jpeg"]

    public static func isSupportedImage(_ path: String) -> Bool {
        supportedImageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Whether the image at `path` is a monochrome VECTOR (an SVG) — the tintable half of `.image`.
    public static func isVectorImage(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "svg"
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
