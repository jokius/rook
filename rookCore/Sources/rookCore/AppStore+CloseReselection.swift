import Foundation

extension AppStore {
    /// Picks the next selection after CLOSING the active session at `location`: the most-recently-active
    /// surviving session, else a positional walk.
    ///
    /// The MRU scope narrows to the closing session's own workspace ∩ the VISIBLE set (`navigableSessions`,
    /// so BOTH the flagged list and the focus filter apply) — an unscoped survivor could yank the user into
    /// another workspace, which is more disorienting than the positional neighbor it replaces, and a pick
    /// the sidebar is not rendering would strand the selection on a row that does not exist. Exhausting a
    /// scope WIDENS through three levels: that workspace's visible sessions, everything visible, then the
    /// whole tree. The last level is what makes "widen when exhausted" mean widen — without it, closing the
    /// only marked workspace's last session would drop straight to a positional jump into the first
    /// workspace.
    ///
    /// A pick outside the marked set is already handled: every caller runs
    /// `disableFocusIfSelectionOutsideSet` on it, which switches the filter off (keeping the set) to reveal
    /// the target — reachable only from the whole-tree level, since the two narrower ones are in-set by
    /// construction.
    ///
    /// The scope is built from the TREE, so a session already removed there cannot come back even when it
    /// survives in `sessionRecency` (the soft-close paths keep it there on purpose, for undo).
    func closeReselectionTarget(after location: (workspaceIndex: Int, sessionIndex: Int)) -> UUID? {
        let visible = Set(navigableSessions.map(\.id))
        let everything = Set(workspaces.flatMap(\.sessions).map(\.id))
        let inWorkspace = Set(workspaces[location.workspaceIndex].sessions.map(\.id))
        let sameWorkspace = inWorkspace.intersection(visible)
        let scope = sameWorkspace.isEmpty ? (visible.isEmpty ? everything : visible) : sameWorkspace
        if let recent = sessionRecency.top(1, in: scope).first { return recent }
        // `reselectionTarget` walks the whole tree positionally, so under a narrowing it can land on a row
        // the sidebar isn't rendering (reachable when no scoped session has ever been activated — e.g. the
        // first close after restoring a snapshot with no persisted recency). Keep the fallback inside the
        // narrowing, but keep it POSITIONAL: the nearest in-scope neighbor, so the worst case really is the
        // old neighbor behavior scoped to the visible set. `narrowed` keys on the MODE/FLAG rather than on
        // the scope, so it stays true after the widening — and once the widening reached the whole tree
        // there is nothing left to keep the pick inside anyway, since leaving no session selected would
        // leave no terminal.
        let narrowed = sidebarMode == .flagged || focusEnabled
        if narrowed, let inScope = nearestInScopeTarget(after: location, scope: scope) {
            return inScope
        }
        return reselectionTarget(after: location)
    }

    /// `reselectionTarget`'s walk restricted to `scope`, over the tree FLATTENED in sidebar order: the
    /// in-scope session that shifted into the removed slot, else the nearest one before it. The walk spans
    /// workspaces because the scope can: once the closing workspace holds nothing in scope the scope has
    /// widened past it, and the flagged sidebar renders its set as one flat cross-workspace list — so the
    /// adjacent row there is the neighboring FLAGGED row, which may live in another workspace.
    /// While the scope is still same-workspace it holds only that workspace's ids, so the flat walk collapses
    /// to the in-workspace one.
    private func nearestInScopeTarget(after location: (workspaceIndex: Int, sessionIndex: Int),
                                      scope: Set<UUID>) -> UUID? {
        let sessions = workspaces[location.workspaceIndex].sessions
        let before = workspaces[..<location.workspaceIndex].reduce(0) { $0 + $1.sessions.count }
        let removedSlot = before + min(location.sessionIndex, sessions.count)
        let flattened = workspaces.flatMap(\.sessions)
        if let next = flattened[removedSlot...].first(where: { scope.contains($0.id) }) { return next.id }
        return flattened[..<removedSlot].last { scope.contains($0.id) }?.id
    }
}
