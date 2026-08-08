import Foundation

private extension KeyedDecodingContainer {
    /// Decodes an OPTIONAL field lossily: a present-but-invalid value (a malformed UUID, an unknown enum
    /// raw value from a newer build, a wrong JSON type from a hand edit) drops to nil instead of throwing.
    /// `Optional` alone tolerates only a MISSING key, so one bad value fails the whole snapshot and
    /// `PersistenceStore.load` starts fresh — wiping every workspace and session over a non-essential field.
    /// (`try?` already flattens the double optional per SE-0230.)
    func lossy<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}

/// The persisted form of the whole app state: a plain value tree that mirrors the
/// `@MainActor` model but carries no live `Session`/`Workspace` references.
///
/// `Codable` for JSON, `Equatable` so tests can assert round-trips, `Sendable` so
/// it can cross the actor boundary — the snapshot is built on `@MainActor` and
/// handed to the file writer as a value.
public struct Snapshot: Codable, Equatable, Sendable {
    /// Bumped when the on-disk shape changes; a mismatch makes the loader start fresh.
    public static let currentVersion = 1

    public var version: Int
    public var selectedSessionID: UUID?
    public var workspaces: [WorkspaceSnapshot]
    /// The window's sidebar width in points, or nil for the default. Optional so a snapshot already on
    /// disk before this field was added still decodes, like the SessionSnapshot fields below.
    public var sidebarWidth: Double?
    /// The window's file-tree panel width in points, or nil for the default. Optional so a snapshot already
    /// on disk before this field was added still decodes, like the fields around it.
    public var fileTreeWidth: Double?

    /// This window's Markdown preview panel width. Optional so a snapshot written before the panel existed
    /// still decodes (the restore falls back to `markdownWidthDefault`).
    public var markdownWidth: Double?
    /// Whether the window's sidebar is shown, or nil for the default (shown). Optional for forward-compat.
    public var sidebarVisible: Bool?
    /// Which view the sidebar renders (tree or flagged flat list), or nil for the default (`.tree`).
    /// Optional so a snapshot already on disk before this field was added still decodes instead of
    /// failing the load and wiping the saved tree, like the fields above.
    public var sidebarMode: SidebarMode?
    /// The workspaces MARKED for the sidebar focus filter, in TREE order, or nil for none. Optional so a
    /// snapshot already on disk before this field was added still decodes (as nil → nothing marked) instead
    /// of failing the load and wiping the saved tree, like the fields above. An ARRAY rather than a Set so
    /// the on-disk list is deterministic instead of following the Set's hash order.
    public var focusedWorkspaceIDs: [UUID]?
    /// WHETHER the marked set filters the tree, or nil for the default (off). Persisted APART from the set
    /// so an off filter keeps its members — the state an involuntary jump (idle auto-follow, attention nav,
    /// a notification reveal) leaves behind, so `workspace.filter on` comes back to the same working set
    /// across a relaunch. Optional for forward-compat like the fields above.
    public var focusEnabled: Bool?
    /// Most-recently-selected session ids, front = current, so the Ctrl-Tab switcher's order survives
    /// a relaunch. Restore drops ids no longer in the tree. Optional so a snapshot already on disk
    /// before this field was added still decodes (as nil → selection only), like the fields above.
    public var sessionRecency: [UUID]?

    public init(version: Int = Snapshot.currentVersion, selectedSessionID: UUID? = nil,
                workspaces: [WorkspaceSnapshot] = [], sidebarWidth: Double? = nil, fileTreeWidth: Double? = nil,
                markdownWidth: Double? = nil,
                sidebarVisible: Bool? = nil,
                sidebarMode: SidebarMode? = nil, focusedWorkspaceIDs: [UUID]? = nil, focusEnabled: Bool? = nil,
                sessionRecency: [UUID]? = nil) {
        self.version = version
        self.selectedSessionID = selectedSessionID
        self.workspaces = workspaces
        self.sidebarWidth = sidebarWidth
        self.fileTreeWidth = fileTreeWidth
        self.markdownWidth = markdownWidth
        self.sidebarVisible = sidebarVisible
        self.sidebarMode = sidebarMode
        self.focusedWorkspaceIDs = focusedWorkspaceIDs
        self.focusEnabled = focusEnabled
        self.sessionRecency = sessionRecency
    }

    enum CodingKeys: String, CodingKey {
        case version, selectedSessionID, workspaces, sidebarWidth, fileTreeWidth, markdownWidth, sidebarVisible, sidebarMode
        case focusedWorkspaceIDs, focusEnabled, sessionRecency
    }

    /// The two LEGACY single-workspace focus keys, written by every release before the focus SET existed:
    /// `focusedWorkspaceID` = the EFFECTIVE focus (the mark only while the filter was on) and
    /// `markedWorkspaceID` = the mark behind it. They live in their OWN key type, read only by
    /// `init(from:)`: neither has a stored property, so re-encoding a migrated snapshot DROPS them instead
    /// of writing the legacy keys back on every load-mutate-save, and an extra case in `CodingKeys` above
    /// would block the synthesized `encode(to:)` outright.
    private enum LegacyCodingKeys: String, CodingKey {
        case focusedWorkspaceID, markedWorkspaceID
    }

    /// Custom decode so EVERY optional is LOSSY (see `lossy(_:_:)` above): one bad value drops to nil
    /// instead of failing the entire `Snapshot` and making `PersistenceStore.load` start fresh — wiping
    /// every workspace and session over a non-essential field. `WorkspaceSnapshot` and `SessionSnapshot`
    /// below guard their own optionals the same way, so the tree survives a bad optional at any depth.
    ///
    /// What still throws is identity and payload: `version`, `workspaces`, and each nested `id`/`name`/
    /// `cwd`/`sessions`. That gap is real and unclosed, not a safe floor: a hand-edited `"cwd": 5` on one
    /// session still wipes the whole tree. It stands because the alternatives each cost something this one
    /// does not — recovering the field keeps a session pointing somewhere the user never left it, dropping
    /// the element loses that session silently — never because throwing is cheaper. Pick one deliberately
    /// before treating this line as settled. A parse-level failure is outside all of it: unterminated JSON
    /// never reaches these guards, and `save` writes atomically so the app cannot leave that behind.
    ///
    /// It is ALSO where the two LEGACY focus keys migrate onto the set, and THREE generations have to land
    /// on the right state. (a) Ancient — `focusedWorkspaceID` alone: the field meant "the tree is collapsed
    /// to this workspace", so its presence implied the filter was on → a one-member ENABLED set. (b) The
    /// split shipped before the set — `focusedWorkspaceID` + `markedWorkspaceID`, which is what real files
    /// hold TODAY: there the MARK is the set and the effective id is only the FLAG, so the set is
    /// `markedWorkspaceID ?? focusedWorkspaceID` and the flag is `focusedWorkspaceID != nil`. Reading the
    /// effective id as the set (upstream's migration) would DROP the mark and restore an EMPTY set for the
    /// exact state an involuntary jump leaves behind — the one the split exists to persist. (c) New keys
    /// present: passed through verbatim, and they WIN over any legacy key still in the file.
    /// The legacy values are LOCALS, not stored properties, so a migrated snapshot re-encodes without them.
    ///
    /// The migration gate is ABSENCE of both new keys, which `Result` — not `try?` — can tell from a FAILED
    /// decode (SE-0230 flattens both to nil). On a file whose new keys are malformed, migrating would
    /// resurrect the legacy mark and force the flag on over an explicit `focusEnabled` in the same file:
    /// a filter state the file never stated.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        selectedSessionID = c.lossy(UUID.self, .selectedSessionID)
        workspaces = try c.decode([WorkspaceSnapshot].self, forKey: .workspaces)
        sidebarWidth = c.lossy(Double.self, .sidebarWidth)
        fileTreeWidth = c.lossy(Double.self, .fileTreeWidth)
        markdownWidth = c.lossy(Double.self, .markdownWidth)
        sidebarVisible = c.lossy(Bool.self, .sidebarVisible)
        sidebarMode = c.lossy(SidebarMode.self, .sidebarMode)
        let decodedIDs = Result { try c.decodeIfPresent([UUID].self, forKey: .focusedWorkspaceIDs) }
        let decodedEnabled = Result { try c.decodeIfPresent(Bool.self, forKey: .focusEnabled) }
        if case .success(.none) = decodedIDs, case .success(.none) = decodedEnabled {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let effective = legacy.lossy(UUID.self, .focusedWorkspaceID)
            let marked = legacy.lossy(UUID.self, .markedWorkspaceID)
            focusedWorkspaceIDs = (marked ?? effective).map { [$0] }
            focusEnabled = effective.map { _ in true }
        } else {
            focusedWorkspaceIDs = (try? decodedIDs.get()) ?? nil
            focusEnabled = (try? decodedEnabled.get()) ?? nil
        }
        sessionRecency = c.lossy([UUID].self, .sessionRecency)
    }
}

/// One persisted workspace: its identity, name, and ordered sessions.
public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var sessions: [SessionSnapshot]
    /// Whether the sidebar row was collapsed. Optional AND stored as the inverse of `isExpanded` so a
    /// snapshot already on disk before this field was added still decodes (missing → nil → not collapsed
    /// → expanded, the default) instead of failing the load and wiping the saved tree, like the fields on
    /// `SessionSnapshot`. Only a collapsed workspace writes it (`true`); an expanded one omits it, so an
    /// all-expanded tree serializes byte-identically to a legacy snapshot.
    public var collapsed: Bool?
    /// The sidebar icon's tint as `#rrggbb`, or nil for the theme default. Optional so a snapshot already
    /// on disk before this field was added still decodes (missing → nil → the theme default) instead of
    /// failing the load and wiping the saved tree, like `collapsed` above.
    public var colorHex: String?
    /// The sidebar icon (symbol/emoji/image), or nil for the default glyph. Optional for the same
    /// forward-compat reason as the fields above, and decoded LOSSILY (see `init(from:)`).
    public var icon: WorkspaceIcon?
    /// The workspace's root directory (`Workspace.root`), or nil for none. Optional so a snapshot already
    /// on disk before this field was added still decodes (missing → nil → no root) instead of failing the
    /// load and wiping the saved tree, like the fields above. Optionality is the forward-compat, so the
    /// `Snapshot` version is NOT bumped.
    public var root: String?

    public init(id: UUID, name: String, sessions: [SessionSnapshot], collapsed: Bool? = nil,
                colorHex: String? = nil, icon: WorkspaceIcon? = nil, root: String? = nil) {
        self.id = id
        self.name = name
        self.sessions = sessions
        self.collapsed = collapsed
        self.colorHex = colorHex
        self.icon = icon
        self.root = root
    }

    enum CodingKeys: String, CodingKey {
        case id, name, sessions, collapsed, colorHex, icon, root
    }

    /// Custom decode so every optional is LOSSY (see `lossy(_:_:)` at the top), matching
    /// `Snapshot.init(from:)`: an unknown icon `kind` after a DOWNGRADE, or a hand-edited
    /// `"collapsed": "yes"`, drops that field to nil instead of throwing. A throw here fails the whole
    /// workspace, which fails the `workspaces` array above it, and `PersistenceStore.load` starts fresh —
    /// wiping the tree over one row's expansion arrow. Only `id`/`name`/`sessions` stay strict.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sessions = try c.decode([SessionSnapshot].self, forKey: .sessions)
        collapsed = c.lossy(Bool.self, .collapsed)
        colorHex = c.lossy(String.self, .colorHex)
        icon = c.lossy(WorkspaceIcon.self, .icon)
        root = c.lossy(String.self, .root)
    }
}

/// One persisted session: its identity, optional custom name, and the working
/// directory to re-spawn a fresh shell in. `cwd` is the live `currentCwd`, or the
/// `initialCwd` when no PWD report has arrived yet.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var customName: String?
    public var cwd: String
    /// Whether the session was shown as a vertical split. Optional so a snapshot already
    /// on disk before this field was added still decodes (as nil → not split) instead of
    /// failing the load and wiping the saved tree. On restore the split pane re-spawns a
    /// fresh shell, like the primary.
    public var isSplit: Bool?
    /// The terminal font size in points, or nil to use the ghostty config default. Optional
    /// so a snapshot already on disk before this field was added still decodes (as nil →
    /// default) instead of failing the load and wiping the saved tree.
    public var fontSize: Double?
    /// The split (right) pane's working directory, so each pane restores to its OWN cwd rather than
    /// both re-spawning in the primary's. The live `splitCwd`, or its restore seed when the split
    /// hasn't reported a PWD yet; nil when there is no split. Optional for forward-compat like the
    /// fields above.
    public var splitCwd: String?
    /// The split divider's left-pane fraction, so the side-by-side ratio restores. Within
    /// `AppStore.splitRatioMin...splitRatioMax` (~0.05...0.95): the live capture skips degenerate extremes
    /// and restore clamps to the same bounds. Optional for forward-compat; nil restores the even default.
    public var splitRatio: Double?
    /// Whether the session is in the flagged working-set. Optional so a snapshot already on disk before
    /// this field was added still decodes (as nil → not flagged) instead of failing the load and wiping
    /// the saved tree, like the fields above.
    public var flagged: Bool?
    /// Whether the session's file-tree panel was shown. Optional so a snapshot already on disk before this
    /// field was added still decodes (as nil → hidden) instead of failing the load and wiping the saved
    /// tree, like the fields above. Only visibility is persisted; the panel's root re-derives from the
    /// restored cwd (see `Session.fileTreeRoot`).
    public var fileTreeVisible: Bool?

    /// The Markdown file this session's preview panel was rendering, or nil when it was closed. Absolute, so
    /// it restores as-is. Optional so a snapshot written before the panel existed still decodes.
    public var markdownPath: String?
    /// The main pane's foreground command (full argv) at the last clean quit, re-run on restore when
    /// `AppSettings.restoreRunningCommand` is on. nil when the pane was at its shell prompt (nothing to
    /// restore) or the feature was off. Optional for forward-compat like the fields above.
    public var foregroundCommand: [String]?
    /// The split (right) pane's foreground command (full argv), the split analogue of `foregroundCommand`.
    public var splitForegroundCommand: [String]?
    /// The agent conversation the main pane was running (agent, conversation id, config root), reported by
    /// the agent's own hook. With `AppSettings.resumeAgentSessions` on, a restored pane whose captured
    /// `foregroundCommand` is that same agent resumes THIS conversation instead of starting a blank one.
    /// Optional for forward-compat like the fields above.
    public var agentSession: AgentSessionRef?
    /// The split (right) pane's agent conversation, the split analogue of `agentSession`.
    public var splitAgentSession: AgentSessionRef?
    /// The command the session was created with (`session.new --command`), which exec-replaces the login
    /// shell and so is invisible to libghostty's foreground pid — persisted here so a command session
    /// (e.g. an `ssh …` shortcut) re-runs its command on restore instead of coming back a plain shell. A
    /// live `foregroundCommand` takes precedence at restore. Optional for forward-compat like the fields above.
    public var initialCommand: String?
    /// Whether a `--command` session holds its surface after the command exits (`session.new --command …
    /// --wait`), so a restored command session that re-runs its command holds again instead of vanishing —
    /// keeping the held/closed behavior consistent across restart. nil (missing key) decodes as false.
    /// Optional for forward-compat like the fields above.
    public var commandWait: Bool?
    /// The session's background watermark (image or rasterized text), or nil for none. Optional so a
    /// snapshot already on disk before this field was added still decodes (as nil → no watermark) instead
    /// of failing the load and wiping the saved tree, like the fields above. A `.text` watermark
    /// re-renders its PNG on restore.
    public var backgroundWatermark: BackgroundWatermark?
    /// The main pane's restore-command override (`session.restore`), which wins over `foregroundCommand`
    /// and `initialCommand` on the next launch. Tri-state: nil/MISSING KEY = no override (every snapshot
    /// written before this field existed, so old state restores exactly as it did), `""` = pinned to
    /// nothing (a plain shell), a command = run that shell line verbatim. Sticky — unlike
    /// `foregroundCommand` it is not consumed on restore, so it fires again after every restart. Optional
    /// for forward-compat like the fields above; the snapshot version is deliberately NOT bumped.
    public var restoreCommand: String?
    /// The split (right) pane's restore-command override, the split analogue of `restoreCommand`.
    public var splitRestoreCommand: String?
    /// The shell the session's panes spawn (`Session.shell`), or nil for the app's default. Optional so a
    /// snapshot already on disk before this field was added still decodes (missing → nil → the default
    /// shell) instead of failing the load and wiping the saved tree, like the fields above; optionality IS
    /// the forward-compat, so the `Snapshot` version is deliberately NOT bumped. A session with no shell
    /// writes NO key at all — an all-default tree serializes byte-identically to a legacy snapshot.
    /// The value is stored VERBATIM, never validated here: a malformed one costs a default shell at spawn
    /// (`SurfaceCommand.resolve` degrades), where rejecting it at load would cost the whole session tree.
    public var shell: String?

    public init(id: UUID, customName: String?, cwd: String, isSplit: Bool? = nil, fontSize: Double? = nil,
                splitCwd: String? = nil, splitRatio: Double? = nil, flagged: Bool? = nil,
                foregroundCommand: [String]? = nil, splitForegroundCommand: [String]? = nil,
                agentSession: AgentSessionRef? = nil, splitAgentSession: AgentSessionRef? = nil,
                initialCommand: String? = nil, commandWait: Bool? = nil,
                backgroundWatermark: BackgroundWatermark? = nil,
                fileTreeVisible: Bool? = nil, markdownPath: String? = nil,
                restoreCommand: String? = nil, splitRestoreCommand: String? = nil,
                shell: String? = nil) {
        self.id = id
        self.customName = customName
        self.cwd = cwd
        self.isSplit = isSplit
        self.fontSize = fontSize
        self.splitCwd = splitCwd
        self.splitRatio = splitRatio
        self.flagged = flagged
        self.foregroundCommand = foregroundCommand
        self.splitForegroundCommand = splitForegroundCommand
        self.agentSession = agentSession
        self.splitAgentSession = splitAgentSession
        self.initialCommand = initialCommand
        self.commandWait = commandWait
        self.backgroundWatermark = backgroundWatermark
        self.fileTreeVisible = fileTreeVisible
        self.markdownPath = markdownPath
        self.restoreCommand = restoreCommand
        self.splitRestoreCommand = splitRestoreCommand
        self.shell = shell
    }

    enum CodingKeys: String, CodingKey {
        case id, customName, cwd, isSplit, fontSize, splitCwd, splitRatio, flagged
        case foregroundCommand, splitForegroundCommand, agentSession, splitAgentSession
        case initialCommand, commandWait, backgroundWatermark, fileTreeVisible
        case markdownPath, restoreCommand, splitRestoreCommand, shell
    }

    /// Custom decode so every optional is LOSSY (see `lossy(_:_:)` at the top), matching
    /// `Snapshot.init(from:)`: an unknown watermark `kind`/`fit`/`position` or agent `kind` after a
    /// DOWNGRADE, or any hand-edit typo, drops that field to nil rather than throwing. A throw here fails
    /// the whole `SessionSnapshot`, which fails the `workspaces` array above it, and
    /// `PersistenceStore.load` starts fresh — wiping everything over one session's font size. A dropped
    /// agent ref costs only the resume (the pane still restores and re-runs its agent).
    /// `id` and `cwd` stay strict, and that is the unclosed half: a session that cannot say which it is or
    /// where to spawn is not restorable, but throwing here costs the WHOLE tree, not this one session.
    /// See `Snapshot.init(from:)` above for the trade-off and why it has not been picked yet.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        customName = c.lossy(String.self, .customName)
        cwd = try c.decode(String.self, forKey: .cwd)
        isSplit = c.lossy(Bool.self, .isSplit)
        fontSize = c.lossy(Double.self, .fontSize)
        splitCwd = c.lossy(String.self, .splitCwd)
        splitRatio = c.lossy(Double.self, .splitRatio)
        flagged = c.lossy(Bool.self, .flagged)
        foregroundCommand = c.lossy([String].self, .foregroundCommand)
        splitForegroundCommand = c.lossy([String].self, .splitForegroundCommand)
        agentSession = c.lossy(AgentSessionRef.self, .agentSession)
        splitAgentSession = c.lossy(AgentSessionRef.self, .splitAgentSession)
        initialCommand = c.lossy(String.self, .initialCommand)
        commandWait = c.lossy(Bool.self, .commandWait)
        backgroundWatermark = c.lossy(BackgroundWatermark.self, .backgroundWatermark)
        fileTreeVisible = c.lossy(Bool.self, .fileTreeVisible)
        markdownPath = c.lossy(String.self, .markdownPath)
        restoreCommand = c.lossy(String.self, .restoreCommand)
        splitRestoreCommand = c.lossy(String.self, .splitRestoreCommand)
        shell = c.lossy(String.self, .shell)
    }
}
