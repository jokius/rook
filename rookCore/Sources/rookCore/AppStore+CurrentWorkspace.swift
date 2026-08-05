import Foundation

/// WHICH workspace is current — where a new session lands, what File ▸ Rename Workspace edits, and what a
/// control-channel `active` workspace target resolves to. The rule is a two-term fallback: the freshly
/// created/selected workspace (`AppStore.freshWorkspaceID`) wins while it lives, else the selected session's
/// workspace, else the last one. Split out of `AppStore.swift` to keep that file under the swiftlint size
/// limit; the stored field itself stays on the class, since an extension cannot hold stored properties.
extension AppStore {
    /// The workspace a new session lands in: a freshly created one, else the selected session's, else the
    /// last (nil when there are none). Drives the bottom bar's add actions, File ▸ New Session / Open
    /// Directory / Rename Workspace, and resolves `active` for control-channel workspace targets.
    public var currentWorkspaceID: UUID? {
        if let freshWorkspaceID, workspaces.contains(where: { $0.id == freshWorkspaceID }) {
            return freshWorkspaceID
        }
        if let selectedSessionID, let workspace = workspace(forSession: selectedSessionID) {
            return workspace.id
        }
        return workspaces.last?.id
    }

    /// Makes `workspaceID` the current one and selects its first session when it has one. Both halves are
    /// needed: the first session may already BE the selection, and a same-value write leaves the target
    /// alone; an EMPTY workspace has nothing to select at all, and reporting success while targeting
    /// somewhere else is what made `workspace.select --target <empty>` a lie. Backs `workspace.select`.
    /// False for an id that names no workspace.
    @discardableResult
    public func selectWorkspace(_ workspaceID: UUID) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return false }
        if let first = workspace.sessions.first {
            selectSession(first.id)
            freshWorkspaceID = nil
            return true
        }
        // an empty workspace the filter hides would be a target with no row: reveal it, the same
        // auto-reveal `addWorkspace` performs, so what is current is always on screen. the target itself
        // is live state outside `snapshot()`, so only the widened set is worth a write.
        let marked = focusedWorkspaceIDs
        revealNewFocusMember(workspaceID)
        freshWorkspaceID = workspaceID
        if focusedWorkspaceIDs != marked { save() }
        return true
    }

    /// Drops the fresh-workspace preference when that workspace is the one going away, so an Undo or a
    /// Reopen re-inserting the same id cannot revive it. Every removal path calls this; a reorder must not.
    func forgetFreshWorkspace(_ workspaceID: UUID) {
        if freshWorkspaceID == workspaceID { freshWorkspaceID = nil }
    }

    /// Drops the target when the focus filter has hidden it, so turning the filter off later cannot make it
    /// current again — hiding it hands targeting back for good. Called from the one focus commit point.
    func forgetHiddenFreshWorkspace() {
        guard let freshWorkspaceID else { return }
        if !visibleWorkspaces.contains(where: { $0.id == freshWorkspaceID }) { self.freshWorkspaceID = nil }
    }
}
