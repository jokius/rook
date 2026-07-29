import rookCore
import Foundation

/// The sidebar's WORKSPACE focus filter for `AppActions` — the row menu's Focus/Unfocus and Add to /
/// Remove from Focus, the keybind/menu/palette entry points, the filter toggle, and Clear Focus.
/// Distinct from `AppActions+Focus.swift`, which owns SESSION/PANE first-responder mechanics; this file
/// only drives `AppStore`'s marked-workspace set and its tree filter.
///
/// Every one of these is frontmost-scoped (`store`) and gated on `uiActionsEnabled` like the rest of the
/// action seam: the callers are the menu bar, the palette, the keybind and the sidebar, all of which act
/// on the window the user is looking at.
extension AppActions {
    /// Focus (or unfocus) a workspace — collapses the sidebar tree to that workspace's subtree, or clears
    /// focus when it is already the ONLY marked workspace and the filter is applied (marked-but-not-filtering
    /// re-applies instead of clearing, so the item still narrows). A replace-toggle: any other marked set is
    /// replaced by this one workspace. Driven by the sidebar workspace row's "Focus"/"Unfocus" context-menu
    /// item. The toggle semantic itself lives in `AppStore.toggleFocusedWorkspace`, shared with
    /// `workspace.focus toggle`, so the GUI and the wire cannot mean different things by "toggle". Clean
    /// no-op on an unknown id (the store guards it).
    func focusWorkspace(_ id: UUID) {
        guard uiActionsEnabled, let store else { return }
        store.toggleFocusedWorkspace(id)
    }

    /// Add or remove ONE workspace from the marked set, leaving the other members alone — the sidebar
    /// workspace row's "Add to Focus"/"Remove from Focus" item, which computes its own direction from the
    /// store and so needs no toggle mode. Adding MARKS ONLY, never switching the filter on, so the rows of
    /// the workspaces still to be marked stay on screen; removing disables the filter once the set empties.
    /// Clean no-op on an unknown id (the store guards it).
    func setFocusMembership(_ id: UUID, member: Bool) {
        guard uiActionsEnabled, let store else { return }
        store.setFocusMembership(id, member: member)
    }

    /// Focus (or unfocus) the current workspace (the one new sessions land in) — the entry point for the
    /// `focus_workspace` keybind, the View menu, and the action palette, which have no clicked row.
    /// No-op when there is no current workspace.
    func focusActiveWorkspace() {
        guard let id = store?.currentWorkspaceID else { return }
        focusWorkspace(id)
    }

    /// Mark the current workspace as a set member, leaving the other members alone — the View menu and
    /// action-palette entry point, which have no clicked row. The ADDITIVE sibling of
    /// `focusActiveWorkspace`, which REPLACES the set with the current workspace. No-op when there is no
    /// current workspace.
    func addActiveWorkspaceToFocus() {
        guard let id = store?.currentWorkspaceID else { return }
        setFocusMembership(id, member: true)
    }

    /// Flip the focus filter on or off WITHOUT touching the marked set, so peeking at the whole tree and
    /// coming back costs one toggle each way. The store refuses to enable an empty set, which is the same
    /// state the menu item renders disabled in, so the two agree by construction.
    func toggleFocusFilter() {
        guard uiActionsEnabled, let store else { return }
        store.setFocusEnabled(!store.focusEnabled)
    }

    /// Clear the marked workspace set entirely, restoring the full tree. A plain menu/palette "Clear Focus"
    /// item; the store's own mutator is a clean no-op when nothing is marked. Distinct from
    /// `toggleFocusFilter`, which KEEPS the set and only stops applying it.
    func clearFocus() {
        guard uiActionsEnabled, let store else { return }
        store.clearFocus()
    }
}
