import rookCore
import AppKit

/// `WorkspaceSidebar.Coordinator` reconcile — the diff that decides between a full `rebuildAndReload`
/// (a tree SHAPE change) and a targeted per-row `reloadItem` (a row CONTENT change), the `TreeShape`/
/// `RowContent` signals it compares, and the expand/collapse delegate callbacks whose deferred,
/// coalesced `scheduleRollUpRefresh` re-runs that diff for the andon roll-up glyph. Split out of
/// `WorkspaceSidebar.swift` to keep that file under the swiftlint size limit.
///
/// The state the diff compares against — `lastShape`, `lastMode`, `lastRowContent`,
/// `pendingRollUpRefresh`, plus the `roots`/`nodeCache`/`expandedWorkspaceIDs` the rebuild rewrites —
/// stays in the main file, because Swift forbids STORED properties in an extension (the same reason the
/// lazy icon caches stay behind for `WorkspaceSidebar+RowRendering`). Reading them from here is what made
/// them internal rather than private.
extension WorkspaceSidebar.Coordinator {
    /// The tree SHAPE: a workspace's id and its ordered session ids. Equal shapes across an update
    /// mean no add/remove/move/reorder, so a row's content change (name/icon/badge) is handled by a
    /// targeted per-row reload instead of a full rebuild. Row TEXT is deliberately NOT here: a
    /// cwd-driven `displayName` change must not trigger a full `reloadData` + re-expand (which
    /// re-lays-out every sidebar row and jitters their labels horizontally).
    struct TreeShape: Equatable {
        let workspaceID: UUID
        let sessionIDs: [UUID]
    }

    /// A row's visible content: its label (workspace name or session `displayName`), whether the
    /// session has a split (the split-rectangle icon), the unseen-badge count, and the agent-status
    /// indicator (a session's own, a workspace's andon roll-up). A delta reloads just that one row.
    /// Uses `hasSplit` (not `isSplit`) so the icon persists while a split is hidden.
    struct RowContent: Equatable {
        let label: String
        let hasSplit: Bool
        let unseen: Int
        let indicator: AgentIndicator
        /// Whether the session is flagged (tree-mode filled-icon variant). A change re-badges
        /// just this row via `reloadItem`. Always false for workspace rows.
        let flagged: Bool
        /// The workspace's icon tint (`#rrggbb`), or nil for the theme default. Folded in so a
        /// `workspace.color` change re-renders just that row; always nil for session rows.
        let colorHex: String?
        /// The workspace's custom icon, or nil for the default glyph. Folded in so a `workspace.icon`
        /// change re-renders just that row; always nil for session rows.
        let icon: WorkspaceIcon?
        /// The coding agent running in the session's focused pane (`AgentMonitor` detects it), or nil.
        /// Folded in so an agent starting/exiting re-renders just that row; always nil for workspace rows.
        let agent: AgentKind?
        /// Whether the workspace is a member of the focus set (the heavy-weight icon variant). Tracks
        /// MEMBERSHIP only — a SEPARATE field from the session-only `flagged`, and independent of
        /// `focusEnabled` — so marking a workspace re-renders just that row via `reloadItem` while the
        /// filter is OFF (with it on the tree shape changes too and the rebuild branch takes over).
        /// Always false for session rows.
        let focusMember: Bool
    }

    /// Decides between a full rebuild (a SHAPE change: add/move/close/reorder) and a targeted
    /// per-row reload (a content change: rename, cwd-driven name, split open/close, badge). Content
    /// changes never rebuild — that full `reloadData` + re-expand re-lays-out every row and jitters
    /// their labels. A reload during an in-progress rename is skipped so a tick can't drop the edit.
    func reconcile() {
        // a mode flip swaps the whole data source (tree ↔ flat flagged list), so rebuild regardless of
        // the shape diff; otherwise compare the mode-appropriate shape.
        let shape = currentShape()
        if store.sidebarMode != lastMode || shape != lastShape {
            lastMode = store.sidebarMode
            lastShape = shape
            rebuildAndReload()
            snapshotRowContent()
            return
        }
        reloadChangedContentRows()
    }

    /// The structural shape for the current mode: the workspace tree (workspace id + ordered session
    /// ids) in `.tree`, or a single flat group of the flagged session ids in `.flagged`. A change here
    /// means an add/remove/move/reorder (or a flag/unflag in flagged mode) and forces a full rebuild.
    /// The tree case derives from `visibleWorkspaces` (the focused workspace alone when focused, else
    /// all), so a focus on/off — which changes the rendered root set — registers as a shape change.
    private func currentShape() -> [TreeShape] {
        switch store.sidebarMode {
        case .tree:
            return store.visibleWorkspaces.map { TreeShape(workspaceID: $0.id, sessionIDs: $0.sessions.map(\.id)) }
        case .flagged:
            return [TreeShape(workspaceID: Self.flaggedShapeID, sessionIDs: store.flaggedSessions.map(\.id))]
        }
    }

    /// Reloads only the rows whose visible content (label, split icon, or badge) changed — the
    /// session row and, for a badge roll-up, its workspace row. A per-row `reloadItem` re-renders
    /// just that row at its stable frame, so a name/cwd update never re-lays-out the whole tree.
    /// Skipped mid-rename so it can't drop an in-progress edit.
    private func reloadChangedContentRows() {
        guard let outline = outlineView, !renameController.isCommitting, !renameController.isEditing else { return }
        func reloadIfChanged(_ id: UUID, _ content: RowContent) {
            guard content != lastRowContent[id] else { return }
            lastRowContent[id] = content
            if let node = nodeCache[id] { outline.reloadItem(node) }
        }
        for workspace in store.workspaces {
            reloadIfChanged(workspace.id, rowContent(forWorkspace: workspace))
            for session in workspace.sessions {
                reloadIfChanged(session.id, rowContent(forSession: session, workspaceName: workspace.name))
            }
        }
    }

    /// Records the current visible content (label, split icon, badge) of every row (keyed by their
    /// distinct ids) so the next reconcile can detect a per-row content delta.
    private func snapshotRowContent() {
        var snapshot: [UUID: RowContent] = [:]
        for workspace in store.workspaces {
            snapshot[workspace.id] = rowContent(forWorkspace: workspace)
            for session in workspace.sessions {
                snapshot[session.id] = rowContent(forSession: session, workspaceName: workspace.name)
            }
        }
        lastRowContent = snapshot
    }

    /// The visible content of a workspace row. The single builder shared by `reloadChangedContentRows`
    /// and `snapshotRowContent` so the change-detection snapshot and the diff can't drift.
    private func rowContent(forWorkspace workspace: Workspace) -> RowContent {
        RowContent(label: workspace.name, hasSplit: false, unseen: effectiveUnseen(workspace.unseenCount),
                   indicator: rollUpIndicator(forWorkspace: workspace), flagged: false, colorHex: workspace.colorHex,
                   icon: workspace.icon, agent: nil,
                   focusMember: store.focusedWorkspaceIDs.contains(workspace.id))
    }

    /// The visible content of a session row. The single builder shared by `reloadChangedContentRows`
    /// and `snapshotRowContent` so the change-detection snapshot and the diff can't drift. Both callers
    /// iterate the `workspace … session` tree, so they pass the owning `workspaceName` in — the label
    /// then needs no `session(withID:)`/`workspace(forSession:)` lookup, keeping the reconcile linear.
    private func rowContent(forSession session: Session, workspaceName: String) -> RowContent {
        RowContent(label: rowLabel(for: session, workspaceName: workspaceName), hasSplit: session.hasSplit,
                   unseen: effectiveUnseen(session.unseenCount),
                   indicator: effectiveIndicator(forSession: session.id), flagged: session.flagged,
                   colorHex: nil, icon: nil, agent: session.agentKind, focusMember: false)
    }

    /// Rebuilds `roots` from the store, reusing cached node instances by id so
    /// NSOutlineView item identity and expansion state stay stable, then reloads
    /// the outline preserving expansion.
    func rebuildAndReload() {
        guard let outline = outlineView else { return }

        // flagged mode: the root's children are the flagged sessions as flat, non-expandable rows; no
        // workspace nodes participate, so they fall out of the cache below.
        if store.sidebarMode == .flagged {
            var seen = Set<UUID>()
            roots = store.flaggedSessions.map { session in
                seen.insert(session.id)
                return node(for: session.id, kind: .session)
            }
            nodeCache = nodeCache.filter { seen.contains($0.key) }
            outline.reloadData()
            updateEmptyState()
            return
        }

        // render only the visible workspaces: the focused workspace's subtree alone when focus is set
        // (and that workspace still exists), else the full tree.
        var seen = Set<UUID>()
        var newRoots: [SidebarNode] = []
        for workspace in store.visibleWorkspaces {
            let wsNode = node(for: workspace.id, kind: .workspace)
            seen.insert(workspace.id)
            wsNode.children = workspace.sessions.map { session in
                seen.insert(session.id)
                return node(for: session.id, kind: .session)
            }
            newRoots.append(wsNode)
        }
        // drop cached nodes for ids no longer present
        nodeCache = nodeCache.filter { seen.contains($0.key) }
        roots = newRoots

        // keep the tracked set in step with the model: drop ids for workspaces that no longer exist,
        // then pick up any the model reports expanded but that aren't tracked yet — a workspace added
        // at runtime defaults `isExpanded == true`, so this renders it open rather than collapsed. A
        // user-collapsed workspace has `isExpanded == false` (so it's excluded) and a programmatic
        // reveal keeps its already-present id (formUnion only adds), so neither is disturbed.
        expandedWorkspaceIDs.formIntersection(Set(store.workspaces.map(\.id)))
        expandedWorkspaceIDs.formUnion(store.workspaces.filter(\.isExpanded).map(\.id))
        // the SOLE focused workspace joins the tracked set HERE, BEFORE the reload — not implicitly via
        // the force-expand below. ORDER IS LOAD-BEARING: a workspace row's roll-up glyph is gated on this
        // set, so a persisted-COLLAPSED zoom target would RENDER collapsed (glyph on) while the content
        // snapshot taken right after read expanded (glyph off), and the deferred refresh — seeing no
        // delta — would strand the duplicate glyph until the next shape change. `didExpand` inserts the
        // same id moments later anyway, so this is no behavior change; do NOT move it back below.
        if let sole = store.soleFocusedWorkspaceID { expandedWorkspaceIDs.insert(sole) }

        // restore expansion from the tracked set rather than the live outline state: a flagged-mode
        // reload drops the workspace nodes, so the outline forgets they were expanded, but the tracked
        // set remembers across the interlude. A SOLE focused workspace is expanded unconditionally —
        // that one is a "zoom in", so its sessions must show even if the workspace was collapsed. It
        // deliberately stops at one member: a filtered tree of 2+ is a LIST, not a zoom, and
        // re-expanding every member on each rebuild would undo the user's collapse of a member over
        // and over while `tree` still reported it `collapsed`. This re-apply is a VIEW restore, not a
        // user action, so suppress the persist: a focused-but-collapsed workspace must keep its
        // persisted collapse (the zoom-in shows it, but doesn't un-collapse it).
        outline.reloadData()
        suppressExpansionPersist = true
        for node in roots where expandedWorkspaceIDs.contains(node.id) {
            outline.expandItem(node)
        }
        suppressExpansionPersist = false
        updateEmptyState()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?[Self.outlineItemUserInfoKey] as? SidebarNode,
              node.kind == .workspace else { return }
        expandedWorkspaceIDs.insert(node.id)
        scheduleRollUpRefresh()
        // persist ONLY a genuine user expand (row click / disclosure triangle). A programmatic reveal or
        // rebuild re-apply sets suppressExpansionPersist, so it updates the visual set above without
        // burning the persisted collapse intent.
        if !suppressExpansionPersist { store.setWorkspaceExpanded(node.id, expanded: true) }
    }

    /// Re-runs the content diff after a workspace's VISUAL expansion changed, so its andon roll-up glyph
    /// (shown only while collapsed) appears or disappears. The tree shape is unchanged, so this lands in
    /// `reloadChangedContentRows` and reloads exactly the one row whose `indicator` flipped.
    ///
    /// Deferred to the next main-loop turn on purpose: the delegate callback fires DURING the
    /// expand/collapse — including the programmatic re-apply inside `rebuildAndReload`, which would
    /// re-enter `reconcile` before it has snapshotted the row content — so a synchronous per-row reload
    /// would land mid-animation and mid-rebuild.
    /// Coalesced by `pendingRollUpRefresh`: a rebuild expands N workspaces in one loop, so without the
    /// guard each `didExpand` would queue its own full-tree content diff (labels included). The flag is
    /// cleared BEFORE the reconcile, so an expand/collapse the reconcile itself causes can queue the next.
    private func scheduleRollUpRefresh() {
        guard !pendingRollUpRefresh else { return }
        pendingRollUpRefresh = true
        DispatchQueue.main.async { [weak self] in
            self?.pendingRollUpRefresh = false
            self?.reconcile()
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?[Self.outlineItemUserInfoKey] as? SidebarNode,
              node.kind == .workspace else { return }
        expandedWorkspaceIDs.remove(node.id)
        scheduleRollUpRefresh()
        // persist only a genuine user collapse; programmatic collapses are suppressed (see didExpand).
        if !suppressExpansionPersist { store.setWorkspaceExpanded(node.id, expanded: false) }
    }
}
