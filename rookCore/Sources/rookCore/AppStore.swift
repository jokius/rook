import Foundation
import Observation

/// A relative step through the flattened session list for keyboard navigation.
/// `next`/`previous` step one and wrap around at the ends, `first`/`last` jump to a tree end.
/// `nextAttention`/`previousAttention` step through only the sessions needing attention
/// (status `blocked` or `completed`), wrapping around.
public enum SessionNavigation: Sendable { case next, previous, first, last, nextAttention, previousAttention }

extension SessionNavigation {
    /// Maps a control-channel direction string to a case. The CLI uses `prev`; the enum case is
    /// `.previous`, so both spellings are accepted. Returns nil for an unknown string.
    public init?(wire: String) {
        switch wire {
        case "next": self = .next
        case "prev", "previous": self = .previous
        case "first": self = .first
        case "last": self = .last
        case "next-attention": self = .nextAttention
        case "prev-attention", "previous-attention": self = .previousAttention
        default: return nil
        }
    }
}

/// The whole app state: the workspace tree and the current selection.
///
/// `@Observable @MainActor` so SwiftUI views observe mutations and all model
/// access is main-actor isolated (implicitly `Sendable` via isolation). Selection
/// is a single `Session.ID?` — workspace rows are non-selectable disclosure
/// headers, so one id is enough; the owning workspace is derived.
@Observable
@MainActor
public final class AppStore {
    public var workspaces: [Workspace]

    /// A CHANGE here drops `freshWorkspaceID`: close, workspace removal, pending-close undo and Reopen
    /// Closed Item all reselect by assigning directly, so centralizing the drop is what keeps a fresh
    /// workspace from outliving a selection made outside `selectSession`. A same-value write must NOT drop
    /// it — reselecting the already-active session is what `navigateSession` with one visible session and
    /// `overlay open --follow` both do, and neither moves the user. `restore(from:)` clears explicitly; it
    /// reloads state rather than selecting.
    public var selectedSessionID: UUID? {
        didSet {
            if selectedSessionID != oldValue { freshWorkspaceID = nil }
        }
    }

    /// The workspace that holds the target without owning the selection: a FOREGROUND create, or a
    /// `selectWorkspace` on an EMPTY one, which has no session to select. Without it a new workspace is
    /// never current while any session is selected — selection does not move on create, so File ▸ Rename
    /// Workspace edited the one you came from and ⌘N put the session there too. Dropped by a selection
    /// CHANGE (the observer above, so a same-value write keeps it), by `selectWorkspace` naming a workspace
    /// that HAS a session, by removing the workspace, by the focus filter hiding it, and by `restore(from:)`.
    /// A BACKGROUND create (`revealNewWorkspace: false`) never sets it, so a script's create cannot steer
    /// the GUI's next add. `internal` (not private) so the `AppStore+CurrentWorkspace`/`+Persistence`
    /// extensions — separate files — can reach it; live state, never persisted.
    var freshWorkspaceID: UUID?

    /// Transient sidebar multi-selection. Not persisted: it is UI command state, while
    /// `selectedSessionID` remains the durable active terminal target.
    var sidebarSelectionRaw: [UUID] = []

    /// Whether this window's sidebar is shown. Per-window UI state, persisted in `Snapshot` (restored on
    /// relaunch); the custom split owns visibility, so the toolbar button, the View menu item, the action
    /// palette, and the `sidebar` control command all flip this one flag.
    public var sidebarVisible = true

    /// Which view this window's sidebar renders: the normal workspace tree or a flat list of the
    /// flagged working-set. Per-window UI state, persisted in `Snapshot` (restored on relaunch);
    /// flipped by the bottom-bar toggle, the View menu, the action palette, and the `sidebar.mode`
    /// control command via `setSidebarMode(_:)`.
    public var sidebarMode: SidebarMode = .tree

    /// The workspaces MARKED for the sidebar focus filter — the working set the tree renders while
    /// `focusEnabled` is on (see `visibleWorkspaces`). Per-window UI state, persisted in `Snapshot`
    /// (restored on relaunch); orthogonal to `sidebarMode` (flagged mode ignores focus). Mutated by the
    /// workspace row menu, the View menu, the palette, and `workspace.focus` — all through the mutators in
    /// `AppStore+Focus.swift`. A member is pruned when its workspace is removed. Read-only outside the
    /// module (`internal(set)`) so the invariant below can only be broken from inside `rookCore`, never by
    /// an app-target line writing the field directly.
    public internal(set) var focusedWorkspaceIDs: Set<UUID> = []

    /// WHETHER that marked set currently filters the tree, split from the set so a hand-curated working set
    /// survives being switched off — an involuntary jump across the tree (idle auto-follow, attention nav, a
    /// notification reveal) stops filtering without destroying what the user picked. Per-window UI state,
    /// persisted in `Snapshot`, and `internal(set)` for the same reason as the set above. Enabled with an
    /// EMPTY set is unrepresentable, which is what makes the filter-ON half of the row-visibility read-back
    /// exact: an applied filter always has at least one visible member. Three guards hold it:
    /// `setFocusEnabled(true)` is a no-op on an empty set (matching the bottom-bar toggle, disabled in
    /// exactly that state), every mutator disables as the set empties (`setFocusMembership`,
    /// `dropFocusMember`), and `restoreFocus(from:)` prunes ids absent from the restored tree. Driven by the
    /// bottom-bar filter toggle, View ▸ Toggle Workspace Filter, `BuiltinAction.toggleWorkspaceFilter`, and
    /// `workspace.filter`.
    public internal(set) var focusEnabled = false

    /// This window's sidebar width in points. Per-window UI state, persisted in `Snapshot`. Driven by the
    /// sidebar divider drag (clamped to `sidebarWidthMin...sidebarWidthMax`); restored on relaunch.
    public var sidebarWidth: Double = AppStore.sidebarWidthDefault

    /// This window's file-tree panel width in points. Per-window UI state, persisted in `Snapshot`. Driven by
    /// the file-tree divider drag (clamped to `fileTreeWidthMin...fileTreeWidthMax`); restored on relaunch.
    public var fileTreeWidth: Double = AppStore.fileTreeWidthDefault

    /// This window's Markdown preview panel width in points. Per-window UI state (like `fileTreeWidth`), so
    /// every session's preview opens at the width the window was last dragged to. Persisted in `Snapshot`,
    /// clamped to `markdownWidthMin...markdownWidthMax` on restore.
    public var markdownWidth: Double = AppStore.markdownWidthDefault

    /// The sidebar width default and drag/restore bounds, shared by the view's divider drag and the
    /// `restore()` clamp so the two can't drift (and a hand-edited snapshot can't drive an out-of-range frame).
    public static let sidebarWidthDefault: Double = 220
    public static let sidebarWidthMin: Double = 160
    public static let sidebarWidthMax: Double = 560

    /// The persisted split-divider left-pane fraction bounds. The live capture skips degenerate extremes
    /// outside this range and `restore()` clamps to it, so the on-disk ratio is always within bounds.
    public static let splitRatioMin: Double = 0.05
    public static let splitRatioMax: Double = 0.95
    /// The even split fraction a never-moved divider renders at (the `HSplitView` default); the base for a
    /// relative `session.resize` when `Session.splitRatio` is still nil.
    public static let splitRatioDefault: Double = 0.5

    /// Clamp a left-pane split fraction to `splitRatioMin...splitRatioMax`.
    public static func clampSplitRatio(_ ratio: Double) -> Double {
        min(splitRatioMax, max(splitRatioMin, ratio))
    }

    /// Most-recently-selected session ids, front = current. Drives the Ctrl-Tab switcher
    /// (`items[1]` is the previous session). `@ObservationIgnored`: read imperatively by the
    /// switcher, not by any SwiftUI view. Persisted in the snapshot so the switcher's order
    /// survives a relaunch.
    @ObservationIgnored public internal(set) var sessionRecency = RecencyStack<UUID>()

    /// The latest session/workspace close that can still be undone. The hidden sessions/workspaces live
    /// in `pendingCloseRecords`; this observed summary is the host-free state the app target presents.
    public var pendingCloseSummary: PendingCloseSummary?

    @ObservationIgnored var pendingCloseRecords: [UUID: PendingCloseRecord] = [:]
    @ObservationIgnored var pendingCloseOrder: [UUID] = []
    @ObservationIgnored var pendingCloseTasks: [UUID: Task<Void, Never>] = [:]
    /// The grace window each pending close was scheduled with, so the summary can carry its countdown and
    /// a hover-pause can reschedule the FULL grace on resume. Keyed by close id, cleaned up on undo/finalize.
    @ObservationIgnored var pendingCloseGrace: [UUID: TimeInterval] = [:]

    @ObservationIgnored let persistence: PersistenceStore
    @ObservationIgnored let recentClosedStore: RecentClosedStore?
    @ObservationIgnored var recentClosedDidChange: (() -> Void)?
    /// The control-event seam: `WindowLibrary` supplies a closure that stamps this store's window id onto
    /// each draft and appends it to the app-wide ring. nil in a standalone store — emits are then no-ops.
    @ObservationIgnored let controlEventSink: ((ControlEventDraft) -> Void)?

    /// Coalesces the high-frequency selection/font saves: a click-storm or a font ramp schedules one
    /// write ~0.3 s after the burst settles instead of hitting disk per event. `save()` cancels any
    /// pending scheduled save, so the quit-flush (`saveAllOpen()` → `save()`) still captures the latest.
    @ObservationIgnored let saveDebouncer = Debouncer()

    /// The quiet window before a scheduled (selection/font) save writes to disk.
    static let saveDebounceInterval: TimeInterval = 0.3

    /// The idle timeout after which the window auto-jumps its selection to the oldest blocked session, or
    /// nil when auto-follow is off (the default). Set by the Settings fan-out; read by `noteUserActivity`
    /// (to arm the debouncer) and the control tree. `@ObservationIgnored`: read imperatively, no view reacts.
    @ObservationIgnored var autoFollowTimeout: TimeInterval?

    /// Whether auto-follow suppresses the jump while the current session is `active` (the opt-in "don't
    /// auto-follow away from a running session" toggle). Default false. `@ObservationIgnored`.
    @ObservationIgnored var autoFollowStayOnActive = false

    /// The last time the user interacted with this window (a keystroke or a manual selection), stamped
    /// unconditionally by `noteUserActivity` so the idle metric is independent of the feature being on.
    /// nil until the first interaction. `@ObservationIgnored`: read imperatively (`idleMs`, the control
    /// tree) and stamped at high frequency, so no view should react to it.
    @ObservationIgnored var lastActivityAt: Date?

    /// Coalesces user activity into a single deferred `autoFollowFire`: each `noteUserActivity` reschedules,
    /// so the fire runs only once the user has been idle for `autoFollowTimeout`. `internal` (NOT private)
    /// so `@testable` tests can drive its `flush()` seam.
    @ObservationIgnored let autoFollowDebouncer = Debouncer()

    /// Coalesces the deferred re-arms the auto-follow status observer schedules into one per runloop turn,
    /// mirroring `DockBadgeController.scheduleRefresh`: a single agent-status flip can fire several live
    /// observation trackers at once, so this collapses them to one re-arm (and one re-registration).
    /// `internal` only so the `AppStore+AutoFollow` extension (a separate file) can reach it.
    @ObservationIgnored var autoFollowRearmScheduled = false

    /// Non-zero while a non-terminal editor or transient overlay in this window owns first responder — the
    /// sidebar inline-rename field or an open command palette. `autoFollowFire` no-ops while this is
    /// positive, so an armed idle jump can't yank the selection out from under an in-progress rename or
    /// reshuffle a palette's action target. A COUNT (not a bool) so the several independent suppressors can
    /// overlap safely: each brackets itself with `suppressAutoFollow`/`resumeAutoFollow`, and a suppressor
    /// lifting while another still holds keeps the jump suppressed. The app owns the first-responder
    /// knowledge; the store just gates on the count. `internal` so the `AppStore+AutoFollow` extension can
    /// read it; mutated only through the two public methods so the app target (a separate module) can't
    /// desync it. `@ObservationIgnored`: read imperatively at fire time, no view reacts.
    @ObservationIgnored var autoFollowSuppressionCount = 0

    public init(workspaces: [Workspace] = [], selectedSessionID: UUID? = nil,
                persistence: PersistenceStore = PersistenceStore(),
                recentClosedStore: RecentClosedStore? = nil,
                recentClosedDidChange: (() -> Void)? = nil,
                controlEventSink: ((ControlEventDraft) -> Void)? = nil) {
        self.workspaces = workspaces
        self.selectedSessionID = selectedSessionID
        self.persistence = persistence
        self.recentClosedStore = recentClosedStore
        self.recentClosedDidChange = recentClosedDidChange
        self.controlEventSink = controlEventSink
    }

    /// The currently selected session, derived from `selectedSessionID`.
    public var activeSession: Session? {
        guard let selectedSessionID else { return nil }
        return session(withID: selectedSessionID)
    }

    /// The auto-generated name for the next new workspace (`workspace 1`, `workspace 2`, …).
    public var defaultWorkspaceName: String {
        "workspace \(workspaces.count + 1)"
    }

    /// Projects this store's workspace/session model into the control-channel `tree` payload. Foreground
    /// command lookup is supplied by the host because live process inspection is platform-specific.
    public func controlTree(foreground: (Session) -> [String]? = { _ in nil },
                            splitForeground: (Session) -> [String]? = { _ in nil },
                            fontSize: (Session) -> Double? = { _ in nil },
                            splitFontSize: (Session) -> Double? = { _ in nil },
                            scratchFontSize: (Session) -> Double? = { _ in nil },
                            quickVisible: () -> Bool? = { nil },
                            zoomedSurface: () -> String? = { nil },
                            pickPending: () -> String? = { nil },
                            dashboardMembers: () -> [String]? = { nil },
                            dashboardHighlighted: () -> String? = { nil },
                            dashboardFontSize: () -> Double? = { nil },
                            dashboardFontMode: () -> String? = { nil }) -> ControlTree {
        let activeID = selectedSessionID
        let activeWorkspaceID = activeID.flatMap { workspace(forSession: $0)?.id }
        let nodes = workspaces.map { workspace in
            let sessions = workspace.sessions.map { session in
                let idle = session.agentIndicator.status == .idle
                let status = idle ? nil : session.agentIndicator.status.rawValue
                let statusPane = idle ? nil : session.agentIndicator.statusPane?.rawValue
                let surfaces = TerminalZoomSurface.allCases.compactMap { surface -> ControlSurfaceNode? in
                    guard surface.isAvailable(in: session) else { return nil }
                    let id = TerminalSurfaceID(sessionID: session.id, surface: surface).rawValue
                    return ControlSurfaceNode(id: id, kind: surface.rawValue,
                                              active: surface.isActive(in: session),
                                              visible: surface.isVisible(in: session))
                }
                return ControlSessionNode(id: session.id.uuidString, name: session.displayName,
                                          cwd: session.effectiveCwd, title: session.oscTitle,
                                          active: session.id == activeID,
                                          split: session.isSplit,
                                          splitRatio: session.hasSplit ? session.splitRatio : nil,
                                          splitFocused: session.hasSplit ? session.splitFocused : nil,
                                          overlay: session.programOverlayActive,
                                          overlaySizePercent: session.programOverlayActive
                                              ? session.overlaySizePercent : nil,
                                          paneOverlays: paneOverlays(session),
                                          hud: hudNode(session),
                                          scratch: session.scratchActive, flagged: session.flagged,
                                          commandWait: (session.initialCommand != nil && session.commandWait) ? true : nil,
                                          fileTreeVisible: session.fileTreeVisible ? true : nil,
                                          fileTreeRoot: session.fileTreeVisible ? session.fileTreeRoot : nil,
                                          markdownPath: session.markdownPath,
                                          foreground: foreground(session),
                                          splitForeground: splitForeground(session),
                                          restoreCommand: session.restoreCommand,
                                          splitRestoreCommand: session.splitRestoreCommand,
                                          agent: session.agentKind?.rawValue,
                                          agentSession: session.agentSession,
                                          splitAgentSession: session.splitAgentSession,
                                          status: status,
                                          statusPane: statusPane,
                                          statusBlink: idle ? nil : (session.agentIndicator.blink ? true : nil),
                                          statusColor: idle ? nil : session.agentIndicator.color,
                                          statusShape: idle ? nil : session.agentIndicator.shape?.rawValue,
                                          background: session.backgroundWatermark,
                                          unseen: session.unseenCount > 0 ? session.unseenCount : nil,
                                          fontSize: fontSize(session),
                                          splitFontSize: splitFontSize(session),
                                          scratchFontSize: scratchFontSize(session),
                                          surfaces: surfaces,
                                          shell: session.shell)
            }
            return ControlWorkspaceNode(id: workspace.id.uuidString, name: workspace.name,
                                        active: workspace.id == activeWorkspaceID,
                                        // `focused` = the EFFECTIVE focus (member AND the filter applies),
                                        // `marked` = membership alone. Keeping them apart is what lets a
                                        // script record a working set and restore it; folding `focused`
                                        // into membership (upstream's shape) would silently break every
                                        // record-then-restore already in the wild.
                                        focused: (focusEnabled && focusedWorkspaceIDs.contains(workspace.id)) ? true : nil,
                                        marked: focusedWorkspaceIDs.contains(workspace.id) ? true : nil,
                                        collapsed: workspace.isExpanded ? nil : true,
                                        color: workspace.colorHex,
                                        icon: workspace.icon?.value, iconKind: workspace.icon?.kind.rawValue,
                                        root: workspace.root,
                                        sessions: sessions)
        }
        return ControlTree(workspaces: nodes, idleMs: idleMs(), autoFollowMs: autoFollowMs,
                           sidebarVisible: sidebarVisible, sidebarMode: sidebarMode.rawValue,
                           quickVisible: quickVisible(), workspaceFilter: focusEnabled,
                           zoomedSurface: zoomedSurface(),
                           dashboardMembers: dashboardMembers(),
                           dashboardHighlighted: dashboardHighlighted(),
                           dashboardFontSize: dashboardFontSize(),
                           dashboardFontMode: dashboardFontMode(), pickPending: pickPending())
    }

    /// The tree's `paneOverlays`: the panes covered by their own overlay, omitted when neither is.
    private func paneOverlays(_ session: Session) -> [String]? {
        let panes = session.openPaneOverlays.map(\.rawValue)
        return panes.isEmpty ? nil : panes
    }

    /// The tree's `hud`: the live panel's spec carrying the slot's EFFECTIVE size on BOTH axes and the
    /// effective position, omitted when no HUD occupies the slot.
    private func hudNode(_ session: Session) -> ControlHudNode? {
        guard session.hudActive, let spec = session.hudSpec else { return nil }
        return ControlHudNode(message: spec.message, detail: spec.detail,
                              spinner: spec.spinner?.rawValue ?? HudSpinner.noneName,
                              backgroundColor: spec.backgroundColor, sizePercent: session.overlaySizePercent,
                              heightPercent: session.hudHeightPercent, position: spec.position.rawValue)
    }

    /// Creates a workspace and appends it. When `revealNewWorkspace` (the default) and the focus filter is
    /// ON, the new workspace JOINS the marked set so it is immediately visible — else `visibleWorkspaces`
    /// would render only the existing members and silently hide it (the auto-reveal contract, like
    /// `addSession`). Widening the set rather than clearing it keeps the rest of the working set filtered;
    /// the user asked for this workspace, so mutating the set here is intentional.
    /// Pass `revealNewWorkspace: false` to leave the filter untouched — a background
    /// `session.new --no-select` create, which must not widen the view.
    /// `revealNewWorkspace` ALSO decides targeting: true makes this workspace `currentWorkspaceID` for as
    /// long as `freshWorkspaceID` holds it, false leaves the target where it is.
    /// Pass `collapsed: true` to create it already collapsed in the sidebar (backs `workspace.new --collapsed`):
    /// a runtime add defaults `isExpanded == true` and renders open, so a collapsed workspace can be built
    /// and filled with `addSession(select: false)` without opening.
    @discardableResult
    public func addWorkspace(name: String, collapsed: Bool = false, revealNewWorkspace: Bool = true) -> Workspace {
        // {AGT_WORKSPACE_NAME} expands unquoted into /bin/sh -c; strip control chars as the OSC path does (TerminalText).
        let workspace = Workspace(name: TerminalText.sanitized(name), isExpanded: !collapsed)
        workspaces.append(workspace)
        if revealNewWorkspace {
            revealNewFocusMember(workspace.id)
            freshWorkspaceID = workspace.id
        }
        scheduleTreeChanged()
        save()
        return workspace
    }

    /// The first workspace whose name exactly equals `name` (case-sensitive, trimmed), or nil when none
    /// matches or `name` is blank. Backs `session.new --workspace-name` (addressing a workspace by its
    /// sidebar label instead of an id).
    public func workspace(named name: String) -> Workspace? {
        // sanitize the needle like the stored names, so a raw control-char lookup still finds its workspace
        // (`session.new --workspace-name` without --create-workspace calls this directly).
        guard let needle = TerminalText.sanitized(name).trimmedOrNil else { return nil }
        return workspaces.first { $0.name == needle }
    }

    /// The workspace named `name`, created if none exists (idempotent); `revealNewWorkspace` (default true)
    /// is forwarded to `addWorkspace` on the create path. Nil only when blank. Backs `--workspace-name --create-workspace`.
    @discardableResult
    public func ensureWorkspace(named name: String, revealNewWorkspace: Bool = true) -> Workspace? {
        // sanitize before the blank check: a control-char-only name must read as blank, not create an
        // unmatchable empty-named workspace on every call.
        guard let needle = TerminalText.sanitized(name).trimmedOrNil else { return nil }
        return workspace(named: needle) ?? addWorkspace(name: needle, revealNewWorkspace: revealNewWorkspace)
    }

    /// Creates a session in the given workspace and, when `select` is true (the default), selects it;
    /// `select: false` appends it in the background, leaving selection/focus/recency untouched (backs
    /// `session.new --no-select`). An optional `name` seeds `customName` (trimmed; blank = the auto
    /// basename, matching `renameSession`). `wait` holds a `--command` session open after the command
    /// exits (`session.new --command … --wait`). `at` nil appends (default); `at` set inserts at the
    /// clamped index (`0...count`), backing `session.new --after`/`--before`. `shell` is the caller's own
    /// shell (`session.new --shell`), persisted so the session's panes keep spawning it across a relaunch;
    /// nil leaves the session on the app's default shell. Returns nil if no workspace matches.
    @discardableResult
    public func addSession(toWorkspace workspaceID: UUID, cwd: String, command: String? = nil,
                           name: String? = nil, wait: Bool = false, at index: Int? = nil,
                           select: Bool = true, shell: String? = nil) -> Session? {
        guard let wsIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        // Both seed values reach a custom-command token that expands unquoted into /bin/sh -c: cwd via
        // initialCwd → effectiveCwd → {AGT_SESSION_PWD} until OSC 7 reports, and name via customName →
        // {AGT_SESSION_NAME}. Strip control characters the same way the OSC path does. See TerminalText.
        let session = Session(initialCwd: TerminalText.sanitized(cwd),
                              customName: name.map(TerminalText.sanitized)?.trimmedOrNil)
        session.initialCommand = command
        session.commandWait = wait
        session.shell = shell
        if let index {
            let destination = max(0, min(index, workspaces[wsIndex].sessions.count))
            workspaces[wsIndex].sessions.insert(session, at: destination)
        } else {
            workspaces[wsIndex].sessions.append(session)
        }
        // a background add (`session.new --no-select`) leaves selection/focus/recency untouched.
        if select {
            selectedSessionID = session.id
            disableFocusIfSelectionOutsideSet(session.id) // a control-driven add into another workspace must reveal it
            recordRecency()
        }
        emitSessionCreated(session, workspace: workspaceID)
        save()
        return session
    }

    /// Duplicates a session: a fresh shell in the SAME workspace, inserted directly after the source, rooted
    /// at the source's focused-pane cwd (`focusedCwd` — the directory the sidebar row shows and the one
    /// "Reveal in Finder" opens, so a duplicate lands where the row says it will).
    ///
    /// ONLY the directory carries over. The duplicate is a plain new session — auto basename (no inherited
    /// `customName`), no split, no scratch, no status, unflagged, no `initialCommand` — i.e. exactly `New
    /// Session` seeded with the source's cwd, not a clone of its state. Returns nil if no session matches.
    ///
    /// Backs the sidebar row's "Duplicate" and the `session.duplicate` control command.
    @discardableResult
    public func duplicateSession(_ id: UUID) -> Session? {
        guard let session = session(withID: id), let location = sessionLocation(ofSession: id) else { return nil }
        return addSession(toWorkspace: location.workspace, cwd: session.focusedCwd, at: location.index + 1)
    }

    /// Selects a session (or clears the selection when passed nil) and persists.
    /// A non-nil id that matches no session is ignored, leaving the current
    /// selection untouched; nil always deselects. Backs the sidebar's
    /// `List(selection:)` so a click persists (debounced ~0.3 s) rather than waiting
    /// for the next structural mutation. Visiting a session clears its unseen badge. An
    /// `autoReset` agent indicator (the one-time `completed` flash) is reset to idle on
    /// BOTH the session moved to (you've seen it) and the one moved from (it must not
    /// persist once you leave it); a non-`autoReset` indicator (active/blocked) is left
    /// untouched (keep-state).
    ///
    /// Returns the DESTINATION's indicator as it stood BEFORE that visit-clear (nil for a nil/unknown id).
    /// Select-then-reveal callers must route on this captured value, not on a re-read of the live session:
    /// the `autoReset` clear above lands between the two steps, so a `completed --auto-reset` block in a
    /// split/scratch pane would otherwise read back `.idle` and drop the user on the main pane instead.
    @discardableResult
    public func selectSession(_ sessionID: UUID?, sidebarSelection selectionIDs: [UUID]? = nil) -> AgentIndicator? {
        if let sessionID, session(withID: sessionID) == nil { return nil }
        let captured = sessionID.flatMap { session(withID: $0)?.agentIndicator }
        let previous = selectedSessionID
        selectedSessionID = sessionID
        if let selectionIDs {
            setSidebarSelection(selectionIDs)
        } else {
            replaceSidebarSelection(with: sessionID)
        }
        disableFocusIfSelectionOutsideSet(sessionID)
        if let sessionID { clearUnseen(sessionID) }
        clearAutoResetIndicator(sessionID) // visit: you've seen it
        clearAutoResetIndicator(previous)  // leave: a one-time status must not linger on the row you left
        recordRecency()
        scheduleSave() // selection fires on every click/keystroke — coalesce the writes
        return captured
    }

    /// Reset a session's agent indicator to idle when it is marked `autoReset` (the one-time `completed`
    /// flash). No-op for nil / an unknown id / a non-autoReset indicator. Routed through `setAgentIndicator`
    /// (not a direct assign) so the clear is a real status transition — a watcher must see the flash END.
    private func clearAutoResetIndicator(_ id: UUID?) {
        guard let id, let session = session(withID: id), session.agentIndicator.autoReset else { return }
        setAgentIndicator(AgentIndicator(), forSession: id)
    }

    /// Clears a session's unseen-notification badge — it's been looked at. No-op for an unknown id.
    /// Not persisted (the count is ephemeral), so it never triggers a `save()`.
    public func clearUnseen(_ sessionID: UUID) {
        session(withID: sessionID)?.unseenCount = 0
    }

    /// Sets a session's agent status indicator (the sidebar status glyph). The single mutation point
    /// for the control channel's `session.status`. Stamps `statusChangedAt` with the current time on any
    /// non-idle status (the attention list's newest-first sort key) and clears it on idle. Clears the
    /// session's `autoFollowConsumed` on a transition INTO blocked, re-arming idle auto-follow for the
    /// fresh episode. No-op for an unknown id. Not persisted (the indicator is ephemeral), so it never
    /// triggers a `save()`.
    public func setAgentIndicator(_ indicator: AgentIndicator, forSession id: UUID) {
        guard let session = session(withID: id) else { return }
        let previous = session.agentIndicator
        let wasBlocked = session.agentIndicator.status == .blocked
        var indicator = indicator
        // normalize a `.right` tag to `.left` when the session has NO split. A promoted survivor's
        // shell keeps its baked `ROOK_PANE=right`, so the agent-status hook re-emits `--pane right` after
        // promotion even though there is no right pane — left unnormalized that re-creates the
        // `split:false` + `statusPane:"right"` contradiction the promotion re-tag fixed, and the sole
        // (`.left`-role-aware) pane could never keystroke-clear it. A hidden-but-LIVE split keeps
        // `hasSplit`, so `.right` stays valid there. `.left`/`.scratch` are untouched.
        // gated on `hasSplit`, NOT `splitSurface == nil`: `toggleSplit`/restore set `hasSplit`
        // synchronously while the deck creates `splitSurface` a render pass later, so a scripted
        // `session.split` + immediate `session.status --pane right` lands in that realization window —
        // there `.right` is the correct forward tag and must NOT be rewritten. `splitSurface != nil`
        // implies `hasSplit` (only `closeSplit`/`closePrimaryPane` clear it, tearing the surface down
        // with it), so `!hasSplit` still covers every genuinely splitless session.
        if indicator.statusPane == .right, !session.hasSplit {
            indicator.statusPane = .left
        }
        session.agentIndicator = indicator
        session.statusChangedAt = indicator.status == .idle ? nil : Date()
        // a fresh block episode (entering blocked from a non-blocked status) re-arms idle auto-follow for
        // this session, so it can pull the user here once more; a re-asserted blocked-over-blocked is not a
        // new episode and stays muted (see Session.autoFollowConsumed).
        if !wasBlocked, indicator.status == .blocked { session.autoFollowConsumed = false }
        // compare the NORMALIZED indicator (post `.right`→`.left`), else a re-asserted `--pane right` on a
        // splitless session emits a spurious status event on every call.
        if previous != indicator { emitStatusChanged(indicator, for: session, id: id) }
    }

    /// Pushes the current selection to the front of the recency stack (the Ctrl-Tab order).
    /// No-op when nothing is selected.
    func recordRecency() {
        if let selectedSessionID { sessionRecency.push(selectedSessionID) }
    }

    func removeFromRecency(_ id: UUID) {
        sessionRecency.remove(id)
    }

    /// Removes a session, tears down its surface, and — if it was the active
    /// session — reselects the most-recently-active surviving session in scope
    /// (see `closeReselectionTarget(after:)`), falling back to the positional neighbor.
    public func closeSession(_ sessionID: UUID) {
        guard let location = location(ofSession: sessionID) else { return }
        let wasActive = selectedSessionID == sessionID
        let workspace = workspaces[location.workspaceIndex]
        let removed = workspaces[location.workspaceIndex].sessions.remove(at: location.sessionIndex)
        emitSessionClosed(removed, workspace: workspace.id)
        recordRecentClosedSession(removed, workspaceID: workspace.id, workspaceName: workspace.name,
                                  workspaceIndex: location.workspaceIndex, sessionIndex: location.sessionIndex)
        removed.surface?.teardown()
        removed.splitSurface?.teardown()
        removed.overlaySurface?.teardown()
        removed.teardownPaneOverlays()
        removed.scratchSurface?.teardown()
        removed.discardHudBody() // a HUD whose surface never realized has no teardown to delete its body file
        WatermarkStorage.removeRenderedText(sessionID: sessionID) // drop any rendered .text PNG; the session is gone
        sessionRecency.remove(sessionID)
        if wasActive {
            selectedSessionID = closeReselectionTarget(after: location)
            replaceSidebarSelection(with: selectedSessionID)
            disableFocusIfSelectionOutsideSet(selectedSessionID) // the reselected session may live outside the marked set
            recordRecency()
        } else {
            pruneSidebarSelection()
        }
        save()
    }

    /// Whether a workspace may be removed: one workspace is always kept, so removal is
    /// allowed only when more than one exists.
    public var canRemoveWorkspace: Bool { workspaces.count > 1 }

    /// Removes a workspace and every session in it, tearing down each session's surfaces
    /// and pruning them from the recency stack. No-ops unless more than one workspace
    /// exists (the last one is kept). If the active session lived in the removed
    /// workspace, reselects through `workspaceRemovalTarget(at:)` — the most recent
    /// still VISIBLE session, falling back to the positional walk only when nothing is
    /// visible, and nil when no sessions remain.
    public func removeWorkspace(_ workspaceID: UUID) {
        guard canRemoveWorkspace, let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let workspace = workspaces[index]
        let removingActive = selectedSessionID.map { id in workspace.sessions.contains { $0.id == id } } ?? false
        // the membership goes into the record BEFORE `dropFocusMember` below prunes it, so Reopen Closed
        // Item can mark the workspace again
        recordRecentClosedWorkspace(workspace, selectedSessionID: removingActive ? selectedSessionID : nil,
                                    focusMember: focusedWorkspaceIDs.contains(workspaceID))
        emitWorkspaceClosed(workspace)
        for session in workspace.sessions {
            session.surface?.teardown()
            session.splitSurface?.teardown()
            session.overlaySurface?.teardown()
            session.teardownPaneOverlays()
            session.scratchSurface?.teardown()
            session.discardHudBody() // a HUD whose surface never realized has no teardown to delete its body file
            WatermarkStorage.removeRenderedText(sessionID: session.id) // drop any rendered .text PNG; the session is gone
            sessionRecency.remove(session.id)
        }
        dropFocusMember(workspaceID) // a marked root is gone; the filter goes with the last member
        workspaces.remove(at: index)
        forgetFreshWorkspace(workspaceID)
        if removingActive {
            selectedSessionID = workspaceRemovalTarget(at: index)
            replaceSidebarSelection(with: selectedSessionID)
            disableFocusIfSelectionOutsideSet(selectedSessionID) // the reselected session may live outside the marked set
            recordRecency()
        } else {
            pruneSidebarSelection()
        }
        save()
    }

    /// Moves a session to another workspace (or reorders within the same one),
    /// keeping the **same** `Session` instance so its attached surface and live
    /// shell survive. `index` is the destination position in the target's session
    /// array **after** the move's removal (clamped to bounds); nil appends.
    /// `selectedSessionID` is unaffected — the id is stable, so a moved active
    /// session stays selected. No-ops if the session or target workspace is
    /// unknown; a same-workspace move to the current slot leaves order unchanged.
    /// Moving the **active** session out of the marked set suspends the focus
    /// filter while KEEPING the set (`disableFocusIfSelectionOutsideSet`, the
    /// auto-reveal contract — the active session must stay inside the visible
    /// set); moving a non-active session leaves the filter intact.
    public func moveSession(_ sessionID: UUID, toWorkspace targetID: UUID, at index: Int? = nil) {
        guard let source = location(ofSession: sessionID) else { return }
        guard let targetIndex = workspaces.firstIndex(where: { $0.id == targetID }) else { return }
        let before = workspaces.map { $0.sessions.map(\.id) }

        let session = workspaces[source.workspaceIndex].sessions.remove(at: source.sessionIndex)
        let destination = max(0, min(index ?? workspaces[targetIndex].sessions.count, workspaces[targetIndex].sessions.count))
        workspaces[targetIndex].sessions.insert(session, at: destination)
        if sessionID == selectedSessionID { disableFocusIfSelectionOutsideSet(sessionID) }
        pruneSidebarSelection()
        if before != workspaces.map({ $0.sessions.map(\.id) }) { scheduleTreeChanged() }
        save()
    }

    /// Moves selected sessions in their current tree order. With `index == nil`, a multi-session context
    /// move appends cross-workspace sessions and leaves sessions already in the target in place; a
    /// one-session call matches `moveSession` and appends even within that workspace. With an explicit
    /// `index`, this is a drag drop: remove every dragged session first, then insert the dragged block at
    /// that post-removal target index. Returns the number of sessions actually moved.
    @discardableResult
    public func moveSessions(_ sessionIDs: [UUID], toWorkspace targetID: UUID, at index: Int? = nil) -> Int {
        guard workspaces.contains(where: { $0.id == targetID }) else { return 0 }
        let before = workspaces.map { $0.sessions.map(\.id) }
        var movingIDs = orderedSessionIDs(matching: Set(sessionIDs))
        // A one-element batch is wire-equivalent to `moveSession`: even within the destination
        // workspace it moves to the end. Multi-selection context moves leave existing members in place.
        if index == nil, movingIDs.count > 1 {
            movingIDs = movingIDs.filter { workspace(forSession: $0)?.id != targetID }
        }
        guard !movingIDs.isEmpty else { return 0 }

        var moving: [Session] = []
        for id in movingIDs {
            guard let location = location(ofSession: id) else { continue }
            moving.append(workspaces[location.workspaceIndex].sessions.remove(at: location.sessionIndex))
        }
        guard let targetIndex = workspaces.firstIndex(where: { $0.id == targetID }), !moving.isEmpty else {
            pruneSidebarSelection()
            return 0
        }
        let destination = max(0, min(index ?? workspaces[targetIndex].sessions.count,
                                     workspaces[targetIndex].sessions.count))
        workspaces[targetIndex].sessions.insert(contentsOf: moving, at: destination)
        if let selectedSessionID, movingIDs.contains(selectedSessionID) { disableFocusIfSelectionOutsideSet(selectedSessionID) }
        pruneSidebarSelection()
        if before != workspaces.map({ $0.sessions.map(\.id) }) { scheduleTreeChanged() }
        save()
        return moving.count
    }

    /// Reorders a session one relative step within its own workspace (`up`/`down`/`top`/`bottom`),
    /// reusing `moveSession` with the same workspace id. No-op (no write) on an unknown id or when
    /// the move would leave order unchanged (already at the end in that direction).
    public func reorderSession(_ id: UUID, _ direction: ReorderDirection) {
        guard let loc = location(ofSession: id) else { return }
        let count = workspaces[loc.workspaceIndex].sessions.count
        guard let dest = direction.destinationIndex(from: loc.sessionIndex, count: count) else { return }
        moveSession(id, toWorkspace: workspaces[loc.workspaceIndex].id, at: dest)
    }

    /// Moves a workspace to `index` among its siblings, mirroring `moveSession`'s
    /// remove/clamp/insert/save shape. `index` is the destination position **after**
    /// the move's removal (clamped to bounds). No-op on an unknown id.
    public func moveWorkspace(_ id: UUID, at index: Int) {
        guard let current = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let before = workspaces.map(\.id)
        let workspace = workspaces.remove(at: current)
        let dest = max(0, min(index, workspaces.count))
        workspaces.insert(workspace, at: dest)
        if before != workspaces.map(\.id) { scheduleTreeChanged() }
        save()
    }

    /// Reorders a workspace one relative step among its siblings (`up`/`down`/`top`/`bottom`),
    /// reusing `moveWorkspace`. No-op (no write) on an unknown id or when the move would leave
    /// order unchanged (already at the end in that direction).
    public func reorderWorkspace(_ id: UUID, _ direction: ReorderDirection) {
        guard let current = workspaces.firstIndex(where: { $0.id == id }) else { return }
        guard let dest = direction.destinationIndex(from: current, count: workspaces.count) else { return }
        moveWorkspace(id, at: dest)
    }

    /// The owning workspace id, the session's index within it, and that workspace's session count, or
    /// nil for an unknown id. Lets the sidebar drag handler resolve owner + index in a single tree walk
    /// instead of re-deriving each piece, while feeding the host-free `SidebarDrop` resolver.
    public func sessionLocation(ofSession id: UUID) -> (workspace: UUID, index: Int, count: Int)? {
        guard let loc = location(ofSession: id) else { return nil }
        let workspace = workspaces[loc.workspaceIndex]
        return (workspace.id, loc.sessionIndex, workspace.sessions.count)
    }

    /// Steps the selection through the flattened VISIBLE/FILTERED session list (`navigableSessions`:
    /// the flagged set in `.flagged` mode, the MARKED workspaces' sessions while the focus filter applies,
    /// else all), in the sidebar's visual order. `next`/`previous` move one and WRAP at the ends WITHIN the
    /// filtered set (`next` on the last lands on the first, `previous` on the first lands on the last, never
    /// leaking across the filter — matching the cyclic attention-nav below); `first`/`last` jump to the
    /// ends of the filtered list. With no/invalid current selection, `next`/`previous` land on its first
    /// session. No-op when the filtered list is empty. Routes through `selectSession`, inheriting recency,
    /// badge clearing, persistence, and workspace derivation. Because the targets are always in-set, nav
    /// never triggers `disableFocusIfSelectionOutsideSet` — that stays the safety net for an explicit cross-set
    /// select. Forwards `selectSession`'s pre-visit indicator for the moved-to session, so nav's reveal step
    /// routes on the status the step landed on; nil when the step found no target (nothing was selected).
    @discardableResult
    public func navigateSession(_ direction: SessionNavigation) -> AgentIndicator? {
        let sessions = navigableSessions
        let ids = sessions.map(\.id)
        guard let first = ids.first, let last = ids.last else { return nil }
        let target: UUID
        switch direction {
        case .first: target = first
        case .last: target = last
        case .next, .previous:
            if let current = selectedSessionID, let i = ids.firstIndex(of: current) {
                let step = direction == .next ? 1 : -1
                target = ids[((i + step) % ids.count + ids.count) % ids.count] // cycle within the filtered set
            } else {
                target = first // no/invalid selection -> first
            }
        case .nextAttention, .previousAttention:
            guard let found = attentionTarget(in: sessions, forward: direction == .nextAttention) else { return nil }
            target = found
        }
        return selectSession(target)
    }

    /// The next/previous session needing attention (status `blocked` or `completed`) in the flattened
    /// order, scanning from the current selection and WRAPPING around. The current session is excluded,
    /// so repeated steps cycle through the others. With no/invalid selection the scan starts from the
    /// tree end opposite the direction. Returns nil when no other attention session exists (a no-op).
    private func attentionTarget(in sessions: [Session], forward: Bool) -> UUID? {
        let ids = sessions.map(\.id)
        let count = ids.count
        guard count > 0 else { return nil }
        let step = forward ? 1 : -1
        let curIndex = selectedSessionID.flatMap { ids.firstIndex(of: $0) }
        let start = curIndex ?? (forward ? -1 : count)
        for k in 1...count {
            let idx = ((start + step * k) % count + count) % count
            if let curIndex, idx == curIndex { break } // wrapped back to the current session, none other
            if sessions[idx].agentIndicator.status.needsAttention { return ids[idx] }
        }
        return nil
    }

    /// Records a session's terminal font size (points) and persists it. No-ops when
    /// unchanged so the cell-size event firing on a DPI change (not a font change)
    /// doesn't write. The save is debounced (~0.3 s) so a font ramp (held ⌘+/⌘−)
    /// coalesces into one write instead of hitting disk per step.
    public func setFontSize(_ sessionID: UUID, _ size: Double) {
        guard let session = session(withID: sessionID), session.fontSize != size else { return }
        session.fontSize = size
        scheduleSave()
    }

    /// Clears every session's per-session font-size override (back to the app default). Called
    /// when an appearance change is applied: the shared ghostty `update_config` resets all live
    /// surfaces to the default size, so the persisted overrides are cleared to match. No-ops (no
    /// write) when nothing was overridden.
    public func resetSessionFontSizes() {
        var changed = false
        for workspace in workspaces {
            for session in workspace.sessions where session.fontSize != nil {
                session.fontSize = nil
                changed = true
            }
        }
        if changed { save() }
    }

    /// Sets (or clears) a session's background watermark and persists it. Clean no-op (no write) for an
    /// unknown id or when the spec is unchanged, so a repeated `session.background` set is idempotent.
    /// Returns whether the spec actually CHANGED, so the app target can gate the (retained, teardown-only-
    /// freed) per-surface config apply on a real change — without it, a scripted set-loop keeps appending
    /// owned configs. The app target applies it to the session's surface(s) after this returns (the
    /// host-free store owns only the spec; the C-boundary apply lives in `ControlServer`/`GhosttySurfaceView`).
    @discardableResult
    public func setBackgroundWatermark(_ watermark: BackgroundWatermark?, forSession id: UUID) -> Bool {
        guard let session = session(withID: id), session.backgroundWatermark != watermark else { return false }
        let previous = session.backgroundWatermark
        session.backgroundWatermark = watermark
        // a `.text` watermark owns a rendered `<id>.png`; switching to anything that isn't `.text` (an
        // image, or nil) leaves it id-keyed but unreferenced, so drop it here. `clear`/teardown also sweep
        // the same id-keyed file, so this is just the eager reclaim for the text→image/nil transition.
        if previous?.kind == .text, watermark?.kind != .text {
            WatermarkStorage.removeRenderedText(sessionID: id)
        }
        save()
        return true
    }

    /// The window-wide non-idle sessions, the single source of truth for the titlebar attention icon
    /// and the `.attention` palette. Spans ALL workspaces (`workspaces.flatMap(\.sessions)`) and
    /// deliberately IGNORES the focus/flagged sidebar filter (unlike `navigableSessions`) — the point
    /// is window-wide visibility even when the sidebar is hidden. Sorted by `attentionRank` ascending
    /// (blocked → active → completed) then `statusChangedAt` DESCENDING (newest change first; a nil
    /// stamp sorts last within its rank group).
    public var attentionSessions: [Session] {
        workspaces.flatMap(\.sessions)
            .filter { $0.agentIndicator.status != .idle }
            .sorted { lhs, rhs in
                let lrank = lhs.agentIndicator.status.attentionRank
                let rrank = rhs.agentIndicator.status.attentionRank
                if lrank != rrank { return lrank < rrank }
                switch (lhs.statusChangedAt, rhs.statusChangedAt) {
                case let (l?, r?): return l > r // newest change first within the rank group
                case (_?, nil): return true     // a stamped session sorts before an unstamped one
                case (nil, _?): return false
                case (nil, nil): return false
                }
            }
    }

    // MARK: - Derivation

    /// The workspace that owns the given session, if any.
    public func workspace(forSession sessionID: UUID) -> Workspace? {
        guard let location = location(ofSession: sessionID) else { return nil }
        return workspaces[location.workspaceIndex]
    }

    /// The session with the given id across all workspaces, if any.
    public func session(withID sessionID: UUID) -> Session? {
        for workspace in workspaces {
            if let session = workspace.sessions.first(where: { $0.id == sessionID }) { return session }
        }
        return nil
    }

    func location(ofSession sessionID: UUID) -> (workspaceIndex: Int, sessionIndex: Int)? {
        for (wi, workspace) in workspaces.enumerated() {
            if let si = workspace.sessions.firstIndex(where: { $0.id == sessionID }) { return (wi, si) }
        }
        return nil
    }

    private func orderedSessionIDs(matching ids: Set<UUID>) -> [UUID] {
        workspaces.flatMap(\.sessions).map(\.id).filter { ids.contains($0) }
    }

    /// Picks the next selection after removing the session at `location`. Prefers
    /// the session that shifted into the removed slot, then the previous one in
    /// that workspace, then the first session of any remaining workspace.
    func reselectionTarget(after location: (workspaceIndex: Int, sessionIndex: Int)) -> UUID? {
        let sessions = workspaces[location.workspaceIndex].sessions
        if location.sessionIndex < sessions.count { return sessions[location.sessionIndex].id }
        if location.sessionIndex > 0, !sessions.isEmpty {
            return sessions[min(location.sessionIndex - 1, sessions.count - 1)].id
        }
        for workspace in workspaces {
            if let first = workspace.sessions.first { return first.id }
        }
        return nil
    }

    func sessionSnapshot(_ session: Session) -> SessionSnapshot {
        SessionSnapshot(id: session.id, customName: session.customName, cwd: session.currentCwd ?? session.initialCwd,
                        isSplit: session.isSplit, fontSize: session.fontSize,
                        splitCwd: session.splitCwd ?? session.initialSplitCwd, splitRatio: session.splitRatio,
                        flagged: session.flagged,
                        foregroundCommand: session.foregroundCommand,
                        splitForegroundCommand: session.splitForegroundCommand,
                        agentSession: session.agentSession,
                        splitAgentSession: session.splitAgentSession,
                        initialCommand: session.initialCommand,
                        commandWait: session.commandWait ? true : nil,
                        backgroundWatermark: session.backgroundWatermark,
                        fileTreeVisible: session.fileTreeVisible ? true : nil,
                        markdownPath: session.markdownPath,
                        restoreCommand: session.restoreCommand,
                        splitRestoreCommand: session.splitRestoreCommand,
                        shell: session.shell)
    }

    func workspaceSnapshot(_ workspace: Workspace) -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: workspace.id, name: workspace.name, sessions: workspace.sessions.map(sessionSnapshot),
                          collapsed: workspace.isExpanded ? nil : true, colorHex: workspace.colorHex,
                          icon: workspace.icon, root: workspace.root)
    }

    func session(from snapshot: SessionSnapshot) -> Session {
        let session = Session(id: snapshot.id, initialCwd: snapshot.cwd, customName: snapshot.customName)
        session.isSplit = snapshot.isSplit ?? false
        session.hasSplit = session.isSplit
        session.fontSize = snapshot.fontSize
        session.initialSplitCwd = snapshot.splitCwd
        session.splitRatio = snapshot.splitRatio.map { min(AppStore.splitRatioMax, max(AppStore.splitRatioMin, $0)) }
        session.flagged = snapshot.flagged ?? false
        session.foregroundCommand = snapshot.foregroundCommand
        session.splitForegroundCommand = snapshot.splitForegroundCommand
        session.agentSession = snapshot.agentSession
        session.splitAgentSession = snapshot.splitAgentSession
        session.initialCommand = snapshot.initialCommand
        session.commandWait = snapshot.commandWait ?? false
        session.wasRestored = true
        session.backgroundWatermark = snapshot.backgroundWatermark
        session.fileTreeVisible = snapshot.fileTreeVisible ?? false
        session.markdownPath = snapshot.markdownPath
        session.restoreCommand = snapshot.restoreCommand
        session.splitRestoreCommand = snapshot.splitRestoreCommand
        session.shell = snapshot.shell
        // A restored-visible panel has no "first show" edge to seed its root, and the view falls back to the
        // LIVE effectiveCwd whenever fileTreeRoot is nil — which would make the tree chase every cd (and lose
        // expansion/scroll on each). So pin the root to the restored cwd here; a hidden panel stays nil and
        // seeds on its first show as usual.
        if session.fileTreeVisible { session.fileTreeRoot = snapshot.cwd }
        return session
    }

    func workspace(from snapshot: WorkspaceSnapshot) -> Workspace {
        Workspace(id: snapshot.id, name: snapshot.name, sessions: snapshot.sessions.map(session(from:)),
                  isExpanded: !(snapshot.collapsed ?? false), colorHex: snapshot.colorHex, icon: snapshot.icon,
                  root: snapshot.root)
    }

}
