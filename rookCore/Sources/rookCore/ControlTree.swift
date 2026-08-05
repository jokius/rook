import Foundation

// The `tree` response's node types: a session's terminal surfaces, the session, the workspace, and the
// tree root with its window-scoped read-back fields. Split out of `ControlProtocol.swift`, which reached
// the 1000-line file budget; these four are one connected group and the largest in that file.

/// A terminal surface as projected into the `tree` response. `id` is the stable control address to pass
/// to `surface.zoom`; `kind` is the user-facing surface name (`left`, `right`, `scratch`, `overlay`).
/// `active`/`visible` are derived from the session's own flags (overlay/scratch/splitFocused), NOT from
/// terminal zoom — and `visible` reads false for a pane behind a FLOATING overlay even though that pane
/// is visually on screen (the derivation treats any open overlay as covering). Address by `id`/`kind`,
/// not by these flags; read the window's zoom state from the tree's top-level `zoomedSurface`.
public struct ControlSurfaceNode: Codable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let active: Bool
    public let visible: Bool

    public init(id: String, kind: String, active: Bool, visible: Bool) {
        self.id = id
        self.kind = kind
        self.active = active
        self.visible = visible
    }
}

/// A session as projected into the `tree` response.
public struct ControlSessionNode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let cwd: String
    /// The raw terminal title from the latest OSC 0/1/2 (a remote host over SSH, a shell
    /// `PROMPT_COMMAND`); nil when none has been reported (omitted from the JSON). This is the
    /// unprocessed `Session.oscTitle`, distinct from `name` (the derived sidebar label, which uses the
    /// title as one fallback) — useful to a script because a remote session's local `cwd` goes stale.
    public let title: String?
    public let active: Bool
    public let split: Bool
    /// The left-pane fraction (0.05...0.95) of a session that HAS a split pane (shown or hidden), or nil
    /// when the session has no split OR the ratio was never explicitly set (via `session.resize` or a
    /// divider drag), in which case the divider sits at the default 0.5. The read side of `session.resize`
    /// — record it before maximizing a pane so a script can restore the exact divider position (the applied
    /// ratio is otherwise echoed only on the `session.resize` call itself).
    public let splitRatio: Double?
    /// For a session that HAS a split pane (shown or hidden), which pane holds keyboard focus: `true` = the
    /// split (right) pane, `false` = the main (left) pane; nil when the session has no split (omitted from
    /// the JSON). The read side of `session.focus` — record which pane was focused so a script can restore
    /// it via `session.focus --pane left|right`.
    public let splitFocused: Bool?
    public let overlay: Bool
    /// For an OPEN overlay (`overlay == true`), its size: nil/omitted = the FULL-pane overlay, else the
    /// floating panel's percent of the pane (1...100). Absent when no overlay is open. The read side of
    /// `session.overlay.resize` — record the current size before resizing so a script can restore it exactly.
    public let overlaySizePercent: Int?
    /// The panes covered by their OWN overlay, ordered left then right (`["left"]`, `["right"]`,
    /// `["left","right"]`); nil/omitted when neither has one. Independent of `overlay`, the session-wide
    /// one — both kinds can be up at once. The read side of `session.overlay.open --pane`; those overlays
    /// are always full-pane, so there is no per-pane size to report.
    public let paneOverlays: [String]?
    public let scratch: Bool
    public let flagged: Bool
    /// For a `--command` session, whether it was created to HOLD its surface after the command exits
    /// (`session.new --command … --wait`) rather than closing immediately; nil/omitted for a plain session
    /// or a non-holding command session. The read side of `session.new --wait`, so a script can record and
    /// restore the flag (it persists across restart, unlike an overlay's live-only wait).
    public let commandWait: Bool?
    /// Whether the session's file-tree panel is shown, or nil when hidden (omitted from the JSON). The read
    /// side of `session.filetree` — so a script can record and restore each session's panel state.
    public let fileTreeVisible: Bool?
    /// The directory the session's file-tree panel is rooted at, or nil when the panel is hidden (omitted
    /// from the JSON). The read side of `session.filetree reroot` — so a script can record where each panel
    /// points and restore it (gated on visibility, like `fileTreeVisible`).
    public let fileTreeRoot: String?
    /// The absolute file the session's Markdown preview panel is rendering, or nil when the panel is closed
    /// (omitted from the JSON). The read side of `session.markdown` — one field, no separate visible flag:
    /// a path IS the open panel, so a script records it and restores with `session.markdown open <path>`.
    public let markdownPath: String?
    /// The LIVE foreground process command (full argv) in the main pane, or nil when the pane is at its
    /// shell prompt (omitted from the JSON). The same capture the restore-running-command feature uses,
    /// surfaced for introspection ("what is each pane running").
    public let foreground: [String]?
    /// The split (right) pane's live foreground command (full argv), the split analogue of `foreground`.
    public let splitForeground: [String]?
    /// The main pane's PERSISTED restore-command override, the read side of `session.restore`. Tri-state:
    /// OMITTED = no override (the auto-capture behavior), `""` = pinned to nothing (a plain shell), a
    /// command = that shell line runs on the next launch. Reported from the persisted state, so a read
    /// after the override already fired still reports what stays pinned — record-then-restore works at any
    /// point in the launch. Unrelated to `foreground`, which is the LIVE process the capture would take.
    public let restoreCommand: String?
    /// The split (right) pane's persisted restore-command override, the split analogue of `restoreCommand`
    /// (the read side of `session.restore --pane right`).
    public let splitRestoreCommand: String?
    /// The coding agent running in the session's FOCUSED pane (`claude`/`codex`, the `AgentKind` raw value),
    /// or nil when the pane runs anything else (omitted from the JSON). OBSERVED from the pane's foreground
    /// process — the classified form of `foreground`/`splitForeground` (which stay the raw argv for anything
    /// this doesn't recognize) — so it needs no hooks and is true even for an agent nobody wired up. It is
    /// what the sidebar row's agent logo renders. Distinct from `status`, which is the agent's SELF-REPORTED
    /// turn state (`session.status`, driven by its hooks): a session can run `claude` (agent) while idle (no
    /// status), or report `blocked` from a pane whose foreground process has since exited.
    public let agent: String?
    /// The agent CONVERSATION the main pane is on (agent, id, config root), as that agent's own hook
    /// reported it over `session.agent` — the read side of that write-only command, so a script can see
    /// which conversation a pane would resume (and restore a ref it recorded). nil/omitted when no hook
    /// ever reported one. Distinct from `agent`, which is merely WHICH agent the pane runs (observed from
    /// the process table and carrying no id).
    public let agentSession: AgentSessionRef?
    /// The split (right) pane's agent conversation, the split analogue of `agentSession`.
    public let splitAgentSession: AgentSessionRef?
    /// The session's agent status (`active`/`completed`/`blocked`) as the `AgentStatus` raw value, or nil
    /// when the session is idle (omitted from the JSON). The read side of `session.status`.
    public let status: String?
    /// Which pane set the session's agent status (`"left"|"right"|"scratch"`, `left`=main, `right`=split),
    /// or nil when idle or unspecified (omitted from the JSON). The read side of `session.status --pane`.
    public let statusPane: String?
    /// Whether the session's agent status glyph is set to blink (pulse for attention), or nil when idle or
    /// not blinking (omitted from the JSON). The read side of `session.status --blink`.
    public let statusBlink: Bool?
    /// The per-call `#rrggbb` glyph-tint override for the session's agent status, or nil when idle or using
    /// the Settings-configured status color (omitted from the JSON). The read side of `session.status --color`.
    public let statusColor: String?
    /// The per-call glyph-silhouette override for the session's agent status (a `StatusShape` raw value),
    /// or nil when idle or drawing the status' semantic default glyph (omitted from the JSON). The read
    /// side of `session.status --shape` — the PER-CALL override only, exactly like `statusColor`, so
    /// record-then-restore treats the two alike.
    public let statusShape: String?
    /// The session's background watermark spec, or nil when none is set (omitted from the JSON). The read
    /// side of `session.background` — set/clear/query symmetry, so a script can inspect the current watermark.
    public let background: BackgroundWatermark?
    /// The session's unseen-notification badge count, or nil when zero (omitted from the JSON). The read
    /// side of the notification badge: `notify` (and terminal OSC 9/777) raise it, `session.seen` clears it.
    /// Ephemeral like `status` — never persisted, so it resets to nil on restart.
    public let unseen: Int?
    /// The default/left pane's live font size in points, resolved via `addressableSurface`: the main pane,
    /// or the promoted split survivor once the primary has exited (the same pane `font --pane left`, and the
    /// default, writes). Nil when that pane isn't realized (omitted from the JSON). Reflects the live cmd
    /// +/- value; the main pane's size is persisted across relaunch, but a promoted survivor's is live-only.
    public let fontSize: Double?
    /// The split (right) pane's live font size in points, or nil when the session has no realized split pane
    /// (omitted). The read side of `font --pane right` — the split's font is otherwise unobservable, being
    /// live-only (not persisted), so record it here before changing it.
    public let splitFontSize: Double?
    /// The scratch terminal's live font size in points, or nil when no scratch surface is realized (omitted).
    /// The read side of `font --pane scratch` (also live-only).
    public let scratchFontSize: Double?
    /// Addressable terminal surfaces owned by this session, or nil when talking to a server that
    /// predates `surface.zoom` (omitted from the JSON — the optional-field pattern every post-v1 tree
    /// addition uses, keeping Codable synthesized). Hidden-but-alive surfaces are included so control
    /// clients can zoom them without mutating split/scratch visibility first.
    public let surfaces: [ControlSurfaceNode]?

    public init(id: String, name: String, cwd: String, title: String? = nil, active: Bool, split: Bool,
                splitRatio: Double? = nil, splitFocused: Bool? = nil,
                overlay: Bool = false, overlaySizePercent: Int? = nil, paneOverlays: [String]? = nil,
                scratch: Bool = false, flagged: Bool = false,
                commandWait: Bool? = nil,
                fileTreeVisible: Bool? = nil, fileTreeRoot: String? = nil, markdownPath: String? = nil,
                foreground: [String]? = nil, splitForeground: [String]? = nil,
                restoreCommand: String? = nil, splitRestoreCommand: String? = nil, agent: String? = nil,
                agentSession: AgentSessionRef? = nil, splitAgentSession: AgentSessionRef? = nil,
                status: String? = nil,
                statusPane: String? = nil, statusBlink: Bool? = nil, statusColor: String? = nil,
                statusShape: String? = nil,
                background: BackgroundWatermark? = nil, unseen: Int? = nil,
                fontSize: Double? = nil, splitFontSize: Double? = nil, scratchFontSize: Double? = nil,
                surfaces: [ControlSurfaceNode]? = nil) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.title = title
        self.active = active
        self.split = split
        self.splitRatio = splitRatio
        self.splitFocused = splitFocused
        self.overlay = overlay
        self.overlaySizePercent = overlaySizePercent
        self.paneOverlays = paneOverlays
        self.scratch = scratch
        self.flagged = flagged
        self.commandWait = commandWait
        self.fileTreeVisible = fileTreeVisible
        self.fileTreeRoot = fileTreeRoot
        self.markdownPath = markdownPath
        self.foreground = foreground
        self.splitForeground = splitForeground
        self.restoreCommand = restoreCommand
        self.splitRestoreCommand = splitRestoreCommand
        self.agent = agent
        self.agentSession = agentSession
        self.splitAgentSession = splitAgentSession
        self.status = status
        self.statusPane = statusPane
        self.statusBlink = statusBlink
        self.statusColor = statusColor
        self.statusShape = statusShape
        self.background = background
        self.unseen = unseen
        self.fontSize = fontSize
        self.splitFontSize = splitFontSize
        self.scratchFontSize = scratchFontSize
        self.surfaces = surfaces
    }
}

/// A workspace and its sessions as projected into the `tree` response.
public struct ControlWorkspaceNode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let active: Bool
    /// Whether the sidebar tree is currently FILTERED and this workspace is one of the workspaces it is
    /// filtered to — nil otherwise (omitted from the JSON). Distinct from `active` (the SELECTED
    /// workspace): the filter hides every workspace outside the marked set. The read side of the write-only
    /// `workspace.focus`, so a script can record which workspaces the tree is collapsed to and restore it.
    ///
    /// EFFECTIVE focus, not membership: it goes nil the moment the filter stops applying, even though the
    /// workspace stays MARKED (see `marked`). That meaning is deliberately frozen — scripts read `focused`
    /// as "the tree is collapsed to this workspace", so widening it to membership when the single focused
    /// workspace became a SET would have silently changed what every existing reader sees. The membership
    /// half is the new `marked` field instead, and the invariant is `focused == marked && workspaceFilter`.
    public let focused: Bool?
    /// Whether this workspace is a MEMBER of the sidebar's focus set — the workspaces the filter shows —
    /// reported independently of whether the filter currently applies; nil when it is not a member
    /// (omitted from the JSON). The pair to read with `tree.workspaceFilter`: `marked` says WHERE the
    /// filter lands, `workspaceFilter` says WHETHER it lands, and `focused` is exactly their conjunction.
    ///
    /// This exists because an INVOLUNTARY jump across the tree (idle auto-follow, attention nav, a
    /// notification reveal) switches the filter off but KEEPS the set, so `marked: true` with no `focused`
    /// is the state `workspace.filter on` re-applies; without this field "marked but not filtering" and
    /// "nothing marked at all" would look identical from outside, and a script could not tell whether
    /// `workspace.filter on` has anywhere to go. It is also what makes a set buildable member by member:
    /// `workspace.focus add` marks without enabling, so each new member is read back here while the whole
    /// tree is still on screen. An EXPLICIT `workspace.focus … off` unmarks, so this then goes nil too.
    ///
    /// A workspace ROW is VISIBLE in the sidebar iff
    /// `tree.sidebarVisible && tree.sidebarMode == "tree" && (!tree.workspaceFilter || marked)` — every
    /// term is on the same `tree` response, so a script evaluates it without a second call. The states,
    /// enumerated: `sidebarVisible == false` renders no sidebar at all; `sidebarMode == "flagged"` renders
    /// a FLAT flagged-session list with NO workspace rows, whatever the filter and the membership say;
    /// `"tree"` with the filter OFF renders EVERY workspace regardless of membership; `"tree"` with the
    /// filter ON renders only the members. Neither shorter form works. `focused` alone (equivalently
    /// `marked && workspaceFilter`) claims nothing is visible whenever the filter is off — where the whole
    /// tree is on screen — and a script correcting for that reaches for `workspace.focus on`, which
    /// REPLACES the set with one workspace rather than re-applying the one it had. A bare
    /// `!workspaceFilter || marked` claims rows are visible in `flagged` mode and behind a hidden sidebar,
    /// where no workspace row renders at all. The filter-ON term is exact rather than approximate, because
    /// `workspaceFilter == true` with an empty set is unrepresentable (enabling an empty set is refused,
    /// and restore prunes stale ids then disables when the set comes back empty), so an applied filter
    /// always has at least one visible member.
    public let marked: Bool?
    /// Whether this workspace is COLLAPSED in the sidebar tree (`true`), or nil when expanded — the
    /// default — so an all-expanded tree omits the field (matching the persisted `WorkspaceSnapshot.collapsed`).
    /// The read side of the write-only `workspace.collapse`/`workspace.expand` and `workspace.new --collapsed`,
    /// so a script can record a workspace's open/closed state and restore it, or toggle by reading it first.
    /// Reports the persisted model state (`!isExpanded`), independent of a transient focus force-reveal.
    /// NOT a reliable read-back for the all-workspace `sidebar.expand`/`sidebar.collapse`: those only post a
    /// notification the mounted sidebar acts on, so with the target window's sidebar HIDDEN they change
    /// nothing to read. The per-workspace commands persist on the store first for exactly that reason.
    public let collapsed: Bool?
    /// The workspace's sidebar icon color as `#rrggbb`, or nil when it uses the theme default (omitted
    /// from the JSON). The read side of `workspace.color` — so a script can record a workspace's color,
    /// change it, and restore it.
    public let color: String?
    /// The workspace's sidebar icon VALUE — an SF Symbol name, an emoji, or the path of the image copied
    /// into the state dir — or nil when it uses the default glyph (omitted from the JSON). Paired with
    /// `iconKind`, which says how to read it. The read side of `workspace.icon`: feeding this value back
    /// to `workspace.icon` restores the icon exactly (an image path already inside the state dir is
    /// re-adopted rather than re-copied).
    public let icon: String?
    /// How to read `icon`: `symbol` | `emoji` | `image`. Omitted when there is no custom icon.
    public let iconKind: String?
    /// The workspace's root directory (`Workspace.root`), or nil when unset (omitted from the JSON). The
    /// read side of `workspace.root` — so a script can record a workspace's root, change it, and restore it.
    public let root: String?
    public let sessions: [ControlSessionNode]

    public init(id: String, name: String, active: Bool, focused: Bool? = nil, marked: Bool? = nil,
                collapsed: Bool? = nil,
                color: String? = nil, icon: String? = nil, iconKind: String? = nil, root: String? = nil,
                sessions: [ControlSessionNode]) {
        self.id = id
        self.name = name
        self.active = active
        self.focused = focused
        self.marked = marked
        self.collapsed = collapsed
        self.color = color
        self.icon = icon
        self.iconKind = iconKind
        self.root = root
        self.sessions = sessions
    }
}

/// The whole workspace tree, the payload of a `tree` response.
public struct ControlTree: Codable, Sendable, Equatable {
    public let workspaces: [ControlWorkspaceNode]
    /// Milliseconds since the last user input in the projected window, or nil before any activity (omitted
    /// from the JSON). A LIVE, continuously-growing delta — `tree`-only because the tree is built fresh on
    /// the main actor per request; it must NOT ride `window.list` (cache-served, so it would freeze between
    /// commands). The read side of the auto-follow idle metric.
    public let idleMs: Int?
    /// The window's auto-follow-blocked timeout in milliseconds, or nil when the feature is disabled
    /// (omitted from the JSON). The read side of the GUI-only Auto-follow setting.
    public let autoFollowMs: Int?
    /// Whether the projected window's sidebar is currently visible. LIVE — built fresh from the window's
    /// store per request — so a script can read the current state (the read side of the write-only
    /// `sidebar` command; e.g. a tmux-style zoom that must restore the sidebar only when it was visible
    /// before zooming). Always present on a `tree` response (the producer passes a non-optional `Bool`),
    /// so unlike `idleMs`/`autoFollowMs` it never omits; the per-window `window.list` copy is nil/omitted
    /// only for a closed window.
    public let sidebarVisible: Bool?
    /// The projected window's sidebar VIEW mode — `SidebarMode.rawValue` (`tree` = the workspace tree,
    /// `flagged` = the flat flagged working-set list). LIVE and always populated on an app-produced `tree`
    /// response; the type stays optional at the protocol level (like the other `tree` fields) for
    /// forward-compat with version skew. The read side of the write-only `sidebar.mode` command, so a script can record the
    /// mode and restore it. `tree`-only (not on `window.list`), since a GUI-only flagged-view toggle would
    /// leave a cached copy stale — read the live tree copy instead.
    public let sidebarMode: String?
    /// Whether the projected window's quick terminal is currently visible. LIVE — resolved app-side per
    /// request from the window's `QuickTerminalController` — so a script can make the `quick` toggle
    /// idempotent (show only when hidden). The read side of the write-only `quick` command. `tree`-only
    /// (not on `window.list`), since a GUI-only ⌃` toggle bypasses the command path and would leave a
    /// cached copy stale — read the live tree copy instead. nil in a host-produced tree with no app closure.
    public let quickVisible: Bool?
    /// Whether the projected window's workspace focus filter currently APPLIES — the flag half of the focus
    /// state, whose member half is each workspace node's `marked`. The read side of the write-only
    /// `workspace.filter` command, so a script can make its toggle idempotent or record-then-restore the
    /// filter around a peek at the whole tree. LIVE, built fresh from the window's store per request.
    ///
    /// It is ONE TERM of the row-visibility predicate, not the whole of it: a workspace row renders iff
    /// `sidebarVisible && sidebarMode == "tree" && (!workspaceFilter || marked)` — see `marked` for the
    /// enumerated states, including `flagged` mode, where no workspace row renders whatever this says.
    /// `true` here always means at least one workspace is marked: enabling an empty set is refused, so the
    /// filter can never be applied to nothing.
    ///
    /// `tree`-only (not on `window.list`), like `sidebarMode`: the bottom-bar toggle, the row menu and an
    /// involuntary jump across the tree all flip it with no command involved, so a cached copy would go
    /// stale. nil in a host-produced tree that does not project a window.
    public let workspaceFilter: Bool?
    /// The control id of the surface terminal zoom currently fills the projected window with —
    /// `surface:<session-id>:<kind>` for a session surface, `quick` for the quick terminal — or
    /// nil/omitted when nothing is zoomed. LIVE — resolved app-side per request from the window's
    /// `TerminalZoomController` — the read side of the write-only `surface.zoom` command, so a script
    /// can check "is it already zoomed" and record-then-restore. `tree`-only (not on `window.list`),
    /// like `quickVisible`: the GUI toggle bypasses the command path and would leave a cached copy stale.
    public let zoomedSurface: String?
    /// The pane refs (`<session-uuid>:left` for a primary pane, `<session-uuid>:right` for a split pane, in
    /// grid order) of the cells the open dashboard shows, or nil/omitted when no dashboard is open. Each cell
    /// is a session+pane, so a split session appears as TWO refs (`:left` and `:right`). LIVE — resolved
    /// app-side per request from the projected window's `DashboardController` — the read side of the
    /// write-only `dashboard` command, so a script can see which panes are on the grid. `tree`-only (not on
    /// `window.list`), like `zoomedSurface`: the keyboard-driven dashboard bypasses the command path and
    /// would leave a cached copy stale. nil in a host-produced tree with no app closure.
    public let dashboardMembers: [String]?
    /// The pane ref (`<session-uuid>:left`/`:right`) of the dashboard's currently highlighted cell (the one
    /// Enter jumps into, focusing that exact pane), or nil/omitted when no dashboard is open. LIVE — resolved
    /// app-side per request from the window's `DashboardController` — the read side of the keyboard highlight
    /// nav. `tree`-only, like `dashboardMembers`.
    public let dashboardHighlighted: String?
    /// The absolute font size in points applied to the dashboard cells, or nil/omitted when no dashboard is
    /// open OR the font is untouched (the members keep their own size). LIVE — resolved app-side per request
    /// from the window's `DashboardController` — the read side of `dashboard --font-size`/`--auto-size`.
    /// `tree`-only, like `dashboardMembers`.
    public let dashboardFontSize: Double?
    /// The dashboard's font mode — `auto` (`--auto-size`), `fixed` (`--font-size`), or `untouched` — or
    /// nil/omitted when no dashboard is open. LIVE — resolved app-side per request from the window's
    /// `DashboardController` — the read side of the font flags. `tree`-only, like `dashboardMembers`.
    public let dashboardFontMode: String?
    /// The id of the picker currently awaiting a choice, or nil when no picker is open.
    public let pickPending: String?

    public init(workspaces: [ControlWorkspaceNode], idleMs: Int? = nil, autoFollowMs: Int? = nil,
                sidebarVisible: Bool? = nil, sidebarMode: String? = nil, quickVisible: Bool? = nil,
                workspaceFilter: Bool? = nil,
                zoomedSurface: String? = nil, dashboardMembers: [String]? = nil,
                dashboardHighlighted: String? = nil, dashboardFontSize: Double? = nil,
                dashboardFontMode: String? = nil, pickPending: String? = nil) {
        self.workspaces = workspaces
        self.idleMs = idleMs
        self.autoFollowMs = autoFollowMs
        self.sidebarVisible = sidebarVisible
        self.sidebarMode = sidebarMode
        self.quickVisible = quickVisible
        self.workspaceFilter = workspaceFilter
        self.zoomedSurface = zoomedSurface
        self.dashboardMembers = dashboardMembers
        self.dashboardHighlighted = dashboardHighlighted
        self.dashboardFontSize = dashboardFontSize
        self.dashboardFontMode = dashboardFontMode
        self.pickPending = pickPending
    }
}
