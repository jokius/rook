import Foundation

/// A user-named group of sessions (e.g. "work", "personal"). A value type with
/// a stable UUID identity; its `sessions` array holds `Session` references.
@MainActor
public struct Workspace: Identifiable {
    public let id: UUID
    public var name: String
    public var sessions: [Session]
    /// Whether the sidebar row is expanded (its session rows shown). Defaults true so a freshly created
    /// workspace opens; persisted per workspace so the collapse state survives a relaunch.
    public var isExpanded: Bool
    /// The sidebar icon's tint as `#rrggbb`, or nil for the theme default. Set from the row's context menu
    /// or `workspace.color`; read back on the `tree` node so a script can record-then-restore it.
    /// Applies only to an icon that renders as a TEMPLATE — a symbol, or an image whose pixels are one
    /// color (see `WorkspaceIcon.isMonochrome`); a colored image and an emoji keep their own colors.
    public var colorHex: String?
    /// The sidebar icon (SF Symbol / emoji / image file), or nil for the default workspace glyph.
    public var icon: WorkspaceIcon?
    /// The workspace's root directory: when set, every NEW session created in this workspace opens here
    /// (a hard override of the global new-session-directory mode). nil = no root, so new sessions fall back
    /// to the global policy. Set from the row's context menu or `workspace.root`; read back on the `tree`
    /// node. Persisted via `WorkspaceSnapshot.root`.
    public var root: String?

    public init(name: String, sessions: [Session] = [], isExpanded: Bool = true, colorHex: String? = nil,
                icon: WorkspaceIcon? = nil, root: String? = nil) {
        id = UUID()
        self.name = name
        self.sessions = sessions
        self.isExpanded = isExpanded
        self.colorHex = colorHex
        self.icon = icon
        self.root = root
    }

    public init(id: UUID, name: String, sessions: [Session] = [], isExpanded: Bool = true, colorHex: String? = nil,
                icon: WorkspaceIcon? = nil, root: String? = nil) {
        self.id = id
        self.name = name
        self.sessions = sessions
        self.isExpanded = isExpanded
        self.colorHex = colorHex
        self.icon = icon
        self.root = root
    }

    /// Total unseen-notification count across this workspace's sessions, for the badge on a
    /// collapsed workspace row (when its session rows are hidden).
    public var unseenCount: Int { sessions.reduce(0) { $0 + $1.unseenCount } }
}
