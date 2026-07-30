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

    /// The agent-status glyph a COLLAPSED workspace row shows — the most important state among its
    /// sessions (`AgentStatus.rollUpRank`: blocked > completed > active), so a blocked agent inside a
    /// collapsed workspace stays visible. The winning session's indicator is carried WHOLE (its
    /// per-call `color`/`shape`/`blink` are the agent's deliberate signals and belong on the parent too),
    /// but `statusPane` is dropped: a pane is meaningless at workspace level, and keeping it would make
    /// the glyph's tooltip claim "(split pane)" about a WORKSPACE. All-idle or empty → `.idle`, which
    /// renders no glyph and collapses the slot.
    ///
    /// TIES go to the FIRST session in `sessions` order — sidebar order, so the winner is the one the user
    /// would point at, and the walk stays stable instead of re-sorting equal ranks. Same "just walk
    /// `sessions`" shape as `unseenCount` above.
    ///
    /// WHOLE means whole: the winner's indicator is COPIED and only `statusPane` nulled, never rebuilt from
    /// `AgentIndicator(status:blink:color:shape:)` — a rebuild would silently drop any field added to
    /// `AgentIndicator` later (`autoReset` rides along today, harmlessly: the roll-up is never persisted and
    /// never reaches `clearAutoResetIndicator`). The walk seeds with an idle indicator and replaces only on a
    /// STRICTLY better rank, which is both the tie rule and the all-idle case: `idle` ranks last, so an idle
    /// session can never win and carry its own stray `blink`/`color` onto the parent.
    public var rollUpIndicator: AgentIndicator {
        var winner = AgentIndicator()
        for session in sessions where session.agentIndicator.status.rollUpRank < winner.status.rollUpRank {
            winner = session.agentIndicator
        }
        winner.statusPane = nil
        return winner
    }
}
