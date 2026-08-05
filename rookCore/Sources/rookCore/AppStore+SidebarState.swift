import Foundation

/// This window's SIDEBAR VIEW STATE: whether the sidebar is shown, which of the two modes it renders
/// (`tree`/`flagged`), each workspace's expand/collapse state, and the per-session `flagged` membership the
/// flat mode projects. Split out of `AppStore.swift` to keep that file under the swiftlint size limit; it is
/// the sibling of `AppStore+Focus.swift`, which owns the other sidebar narrowing (the workspace filter).
extension AppStore {
    /// Sets this window's sidebar visibility and persists it. Clean no-op (no write) when unchanged, so
    /// menu, toolbar, palette, and control callers can delta-compute their desired state without
    /// duplicating the persistence gate. `sidebarVisible` is per-window state saved in this store's
    /// snapshot.
    public func setSidebarVisible(_ visible: Bool) {
        guard sidebarVisible != visible else { return }
        sidebarVisible = visible
        save()
        // refresh the app-target ControlServer's window.list cache: a GUI-only toggle isn't a control
        // command, so without this the cached sidebarVisible would lag until the next command.
        NotificationCenter.default.post(name: .rookSidebarVisibilityChanged, object: nil)
    }

    /// Flips this window's sidebar visibility and persists the new state.
    public func toggleSidebarVisible() {
        setSidebarVisible(!sidebarVisible)
    }

    /// Sets the sidebar mode and persists it. Clean no-op (no write) when the mode is unchanged, so the
    /// delta-computed control/menu callers stay idempotent. BOTH flips swap the whole visible set, so each
    /// reselects when it would hide the active session (`reselectIfSelectionHidden`).
    public func setSidebarMode(_ mode: SidebarMode) {
        guard sidebarMode != mode else { return }
        sidebarMode = mode
        pruneSidebarSelection()
        reselectIfSelectionHidden()
        save()
    }

    /// Sets one workspace's expand/collapse state and persists it. Clean no-op (no write) for an unknown id
    /// or when unchanged. The sidebar calls this for a GENUINE per-row user toggle only (a row click or the
    /// disclosure triangle), never for a programmatic reveal — so a deliberate collapse survives a later
    /// reveal of a session inside the workspace, and toggling one workspace never touches another's saved
    /// state (unlike `setWorkspacesExpanded`, which rewrites the whole tree).
    public func setWorkspaceExpanded(_ id: UUID, expanded: Bool) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }), workspaces[index].isExpanded != expanded else { return }
        workspaces[index].isExpanded = expanded
        save()
    }

    /// Marks each workspace expanded iff its id is in `expandedIDs` and persists the collapse state so it
    /// survives a relaunch. One `save()` for the whole diff; a clean no-op (no write) when nothing changed.
    /// Backs the deliberate all-workspace commands (Expand Workspaces / Collapse Workspaces), which set
    /// every workspace at once; per-row toggles use `setWorkspaceExpanded` instead.
    public func setWorkspacesExpanded(_ expandedIDs: Set<UUID>) {
        var changed = false
        for index in workspaces.indices {
            let expanded = expandedIDs.contains(workspaces[index].id)
            if workspaces[index].isExpanded != expanded {
                workspaces[index].isExpanded = expanded
                changed = true
            }
        }
        if changed { save() }
    }

    /// Sets (or clears) a session's flag — the durable flagged working-set membership the flat sidebar
    /// view projects. Persists the change. Clean no-op (no write) for an unknown id or when the flag is
    /// already in the requested state, so the delta-computed control/menu callers stay idempotent.
    ///
    /// In `.flagged` mode a flag change RESHAPES the visible set, in either direction — unflagging the
    /// active session drops the row rendering it, flagging one fills a list that was empty — so it runs the
    /// same `reselectIfSelectionHidden` the other narrowings do. In tree mode the flag changes no row's
    /// visibility, so the call is inert there beyond repairing a selection something else stranded.
    public func setFlag(_ on: Bool, forSession id: UUID) {
        guard let session = session(withID: id), session.flagged != on else { return }
        session.flagged = on
        pruneSidebarSelection()
        reselectIfSelectionHidden()
        save()
    }

    /// Sets (or clears) multiple sessions' flags in one save. Unknown ids are ignored.
    public func setFlag(_ on: Bool, forSessions ids: [UUID]) {
        let targetIDs = Set(ids)
        guard !targetIDs.isEmpty else { return }
        var changed = false
        for workspace in workspaces {
            for session in workspace.sessions where targetIDs.contains(session.id) && session.flagged != on {
                session.flagged = on
                changed = true
            }
        }
        if changed {
            pruneSidebarSelection()
            reselectIfSelectionHidden() // the batch can unflag the active session too
            save()
        }
    }

    /// Unflags every session across all workspaces in one `save()`. No-ops (no write) when nothing is
    /// flagged. Backs the Clear Flagged action and the `session.flag clear` control mode.
    ///
    /// No `reselectIfSelectionHidden`, unlike the two `setFlag` mutators: clearing EVERY flag leaves the
    /// flagged list empty, so in that mode there is nowhere to move the selection to. Only a PARTIAL clear
    /// would need it.
    public func clearFlags() {
        var changed = false
        for workspace in workspaces {
            for session in workspace.sessions where session.flagged {
                session.flagged = false
                changed = true
            }
        }
        if changed {
            pruneSidebarSelection()
            save()
        }
    }

    /// The flagged sessions across all workspaces in tree order (`workspaces.flatMap(\.sessions)` filtered
    /// by `flagged`). A pure derived projection — the flat sidebar view renders this directly.
    public var flaggedSessions: [Session] {
        workspaces.flatMap(\.sessions).filter(\.flagged)
    }
}
