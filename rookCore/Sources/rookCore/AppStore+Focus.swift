import Foundation

/// The sidebar focus filter, split out of `AppStore.swift` to keep that file under the swiftlint size
/// limit. Behavior of the existing entry points is unchanged; what is new is that the state is TWO bits
/// (`markedWorkspaceID` = which workspace, `focusFilterEnabled` = whether it filters) instead of one
/// optional id.
///
/// Why the split: rook has many ways to jump across the tree that the user did not ask for — idle
/// auto-follow to a blocked session, attention navigation, a notification reveal, the dashboard, the
/// recent-sessions popover. Each of those runs `autoUnfocusIfOutsideFocus`, which used to NIL the focus
/// outright, so a filter could die unattended and there was nothing left to go back to. Now an
/// INVOLUNTARY jump only switches the filter off and the mark survives, so turning the filter back on
/// returns to the same workspace. An EXPLICIT unfocus (the row menu, the palette, `workspace.focus …
/// off`, the pill ✕) still forgets the mark — that is the user saying they are done with it.
extension AppStore {
    /// The EFFECTIVE focus: the marked workspace while the filter is on, else nil. Per-window UI state,
    /// persisted in `Snapshot` (restored on relaunch). When set, the tree renders only that workspace
    /// (see `visibleWorkspaces`); orthogonal to `sidebarMode` (flagged mode ignores focus). Flipped by the
    /// workspace row menu, the bottom-bar pill, the View menu, the palette, and the `workspace.focus`
    /// control command via `setFocusedWorkspace(_:)`. Cleared when the focused workspace is removed.
    ///
    /// Everything outside this file reads and writes THIS, not the two halves, so "focused" keeps meaning
    /// exactly what it always did — the tree is collapsed to this workspace — and the `focused` tree
    /// read-back, the snapshot, and the row menus need no change. Assigning an id marks it AND turns the
    /// filter on; assigning nil turns the filter off AND forgets the mark.
    public var focusedWorkspaceID: UUID? {
        get { focusFilterEnabled ? markedWorkspaceID : nil }
        set {
            markedWorkspaceID = newValue
            focusFilterEnabled = newValue != nil
        }
    }

    /// Sets (or clears) the focused workspace and persists it. Clean no-op (no write) when unchanged, so
    /// the delta-computed control/menu callers stay idempotent. Passing nil unfocuses and forgets the mark.
    public func setFocusedWorkspace(_ id: UUID?) {
        // an explicit unfocus must forget the mark even when the filter is ALREADY off, which is the
        // state an involuntary jump leaves behind. The effective focus reads nil in both cases, so
        // guarding on it alone would early-return and silently keep a mark the user just said they were
        // done with — and then `workspace.filter on` would resurrect a focus they had dismissed.
        guard focusedWorkspaceID != id || (id == nil && markedWorkspaceID != nil) else { return }
        focusedWorkspaceID = id
        pruneSidebarSelection()
        save()
    }

    /// Turns the filter on/off WITHOUT touching which workspace is marked — the "come back to it" leg of
    /// the split, and the only way to re-apply a filter an auto-unfocus dropped. Enabling with nothing
    /// marked is a no-op (there would be nothing to filter to). Clean no-op (no write) when unchanged,
    /// like every other delta-computed setter.
    public func setFocusFilterEnabled(_ enabled: Bool) {
        // enabling needs a mark that still RESOLVES: a mark whose workspace was deleted would switch the
        // filter on while filtering nothing, which reads as "focus restored" to a script but shows the
        // whole tree. Disabling is never gated — it must always be able to undo.
        guard focusFilterEnabled != enabled, !enabled || focusedWorkspaceExists else { return }
        focusFilterEnabled = enabled
        pruneSidebarSelection()
        save()
    }

    /// Applies (`on`), lifts (`off`), or flips (`toggle`) the filter over the CURRENT mark — the host-free
    /// half of the `workspace.filter` control command, so its app-side arm is pure store resolution. Every
    /// mode routes through `setFocusFilterEnabled`, so all three are idempotent and enabling with nothing
    /// marked stays a clean no-op.
    public func applyWorkspaceFilter(_ mode: ControlToggleMode) {
        setFocusFilterEnabled(mode.desiredValue(current: focusFilterEnabled))
    }

    /// Whether the mark names a workspace that still exists — the gate on re-enabling the filter, so a
    /// mark left dangling by a removal cannot switch filtering back on with nothing to filter to.
    private var focusedWorkspaceExists: Bool {
        guard let markedWorkspaceID else { return false }
        return workspaces.contains { $0.id == markedWorkspaceID }
    }

    /// Stops filtering when the newly selected session lives outside the focused workspace, so a cross-set
    /// select (`session.select <id>` of a hidden session, a notification reveal, idle auto-follow, a
    /// move/close that reselects elsewhere) reveals its target — the active session is then always inside
    /// the visible set. Session navigation (`navigateSession`/`session.go`, Ctrl-Tab, attention-nav) is
    /// scoped to the filtered set (`navigableSessions`), so its targets are always in-set and never trip
    /// this — it stays the safety net only for the cross-set cases. No-op when unfiltered, when nothing is
    /// selected, or when the selection is inside the focused workspace. Persistence rides the caller's save.
    ///
    /// Only the FLAG drops: none of the callers is the user asking to give the focus up (most fire while
    /// they are away from the keyboard), so the mark is kept and `setFocusFilterEnabled(true)` restores
    /// the same workspace.
    func autoUnfocusIfOutsideFocus(_ sessionID: UUID?) {
        guard focusFilterEnabled, let markedWorkspaceID, let sessionID else { return }
        if workspace(forSession: sessionID)?.id != markedWorkspaceID { focusFilterEnabled = false }
    }

    /// The focused workspace, resolved from `focusedWorkspaceID` — nil when unfocused OR when the id is
    /// stale (its workspace no longer exists). The single id→workspace lookup the tree filter and the
    /// bottom-bar focus pill both read, so they can't drift.
    ///
    /// The stale case is also what makes a mark kept across a workspace REMOVAL harmless: a mark whose
    /// workspace is gone resolves to nil and filters nothing, and if the removal is undone within the
    /// grace window the same workspace id comes back and the mark is live again.
    public var focusedWorkspace: Workspace? {
        guard let id = focusedWorkspaceID else { return nil }
        return workspaces.first(where: { $0.id == id })
    }

    /// The workspaces the sidebar tree should render: just the focused workspace when the filter is on
    /// AND that workspace still exists, else all workspaces. The source of truth the tree filters on; a
    /// stale focus id (its workspace gone) falls back to the full tree.
    public var visibleWorkspaces: [Workspace] {
        guard let focused = focusedWorkspace else { return workspaces }
        return [focused]
    }
}
