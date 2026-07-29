import rookCore
import AppKit

/// `WorkspaceSidebar.Coordinator` per-row context menu and its actions — the double-click rename
/// trigger, the menu builder, and the `@objc` handlers that drive the store/`AppActions`. Split out of
/// `WorkspaceSidebar.swift` to keep that file under the swiftlint size limit. Selector dispatch from an
/// extension works, so the handlers stay private.
extension WorkspaceSidebar.Coordinator {
    // MARK: - Context menu

    /// Single click on a workspace row toggles its expansion, so the whole row is a hit target for
    /// expand/collapse (not just the disclosure triangle). The toggle is DEFERRED by the double-click
    /// interval: a double-click (`handleDoubleClick`) cancels it, so renaming a workspace no longer flips
    /// it open/closed on the way into edit mode. `action` fires on a genuine click, never during a drag,
    /// so workspace drag-reorder is unaffected.
    @objc func handleSingleClick(_ sender: NSOutlineView) {
        let row = sender.clickedRow
        guard row >= 0, let node = sender.item(atRow: row) as? SidebarNode, node.kind == .workspace else { return }
        // clicking the disclosure triangle already toggles natively — ignore that region so we don't double-toggle.
        if let event = NSApp.currentEvent {
            let point = sender.convert(event.locationInWindow, from: nil)
            if point.x < sender.frameOfOutlineCell(atRow: row).maxX { return }
            // clicking the inline "+" button is handled by the button itself — don't schedule the toggle.
            if let cell = sender.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView,
               let btn = cell.addButton,
               btn.convert(btn.bounds, to: sender).contains(point) { return }
        }
        pendingRowToggle?.cancel()
        let toggle = DispatchWorkItem { [weak self, weak node] in
            guard let self, let node, let outline = self.outlineView else { return }
            self.toggleExpansion(of: node, in: outline)
        }
        pendingRowToggle = toggle
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: toggle)
    }

    @objc func handleDoubleClick(_ sender: NSOutlineView) {
        // a double-click is a rename, not an expand/collapse: cancel the pending single-click toggle.
        pendingRowToggle?.cancel()
        pendingRowToggle = nil
        let row = sender.clickedRow
        guard row >= 0, let node = sender.item(atRow: row) as? SidebarNode else { return }
        renameController.beginEditing(node: node)
    }

    private func toggleExpansion(of node: SidebarNode, in outline: NSOutlineView) {
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    /// Builds the per-row context menu. Resolves the clicked row lazily so the
    /// same menu serves every row.
    func menu(forRow row: Int) -> NSMenu? {
        guard let outline = outlineView, row >= 0, let node = outline.item(atRow: row) as? SidebarNode else { return nil }
        let menu = NSMenu()
        // manage enabled state explicitly (the Delete item is disabled at the last workspace)
        // rather than via the responder-chain auto-enabling.
        menu.autoenablesItems = false
        let sessionTargets = node.kind == .session ? store.sidebarSelectionTargets(forContextSession: node.id) : []
        let sessionCount = sessionTargets.count

        // "Clear Status" sits first for a session row that has a status to clear (same effect as
        // `rookctl session status idle`).
        if node.kind == .session, sessionTargets.contains(where: { store.session(withID: $0)?.agentIndicator.status != .idle }) {
            let clearStatus = NSMenuItem(title: sessionCount == 1 ? "Clear Status" : "Clear Statuses",
                                         action: #selector(menuClearStatus(_:)), keyEquivalent: "")
            clearStatus.target = self
            clearStatus.representedObject = SessionBatchRequest(sessionIDs: sessionTargets)
            menu.addItem(clearStatus)
            menu.addItem(.separator())
        }

        if node.kind == .workspace || sessionCount <= 1 {
            let rename = NSMenuItem(title: "Rename", action: #selector(menuRename(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = node
            menu.addItem(rename)
        }

        switch node.kind {
        case .session:
            // "Duplicate Session" opens a fresh shell in this session's directory, right after it —
            // single-selection only (like Rename/Reveal in Finder), and sitting next to Rename mirrors
            // Finder's ordering. The title matches the New Session / Close Session naming on the same menu.
            if sessionCount == 1 {
                let duplicate = NSMenuItem(title: "Duplicate Session", action: #selector(menuDuplicate(_:)), keyEquivalent: "")
                duplicate.target = self
                duplicate.representedObject = node
                menu.addItem(duplicate)
            }
            let targets = store.workspaces.filter { workspace in
                sessionTargets.contains { ownerWorkspaceID(ofSession: $0) != workspace.id }
            }
            if !targets.isEmpty {
                let moveTo = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for target in targets {
                    let item = NSMenuItem(title: target.name, action: #selector(menuMove(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = SessionBatchRequest(sessionIDs: sessionTargets, targetID: target.id)
                    submenu.addItem(item)
                }
                moveTo.submenu = submenu
                menu.addItem(moveTo)
            }
            // "Flag"/"Unflag" toggles the session's flagged working-set membership; the label
            // reflects the current state.
            let allFlagged = !sessionTargets.isEmpty && sessionTargets.allSatisfy { store.session(withID: $0)?.flagged == true }
            let flagTitle: String
            if sessionCount == 1 {
                flagTitle = allFlagged ? "Unflag" : "Flag"
            } else {
                flagTitle = allFlagged ? "Unflag Sessions" : "Flag Sessions"
            }
            let flag = NSMenuItem(title: flagTitle, action: #selector(menuToggleFlag(_:)), keyEquivalent: "")
            flag.target = self
            flag.representedObject = SessionBatchRequest(sessionIDs: sessionTargets)
            menu.addItem(flag)
            if sessionCount == 1 {
                let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(menuRevealInFinder(_:)), keyEquivalent: "")
                reveal.target = self
                reveal.representedObject = node
                reveal.isEnabled = actions.canRevealSessionInFinder(node.id, in: store)
                menu.addItem(reveal)
            }
            let closeTitle = sessionCount == 1 ? "Close Session" : "Close \(sessionCount) Sessions"
            let close = NSMenuItem(title: closeTitle, action: #selector(menuClose(_:)), keyEquivalent: "")
            close.target = self
            close.representedObject = SessionBatchRequest(sessionIDs: sessionTargets)
            menu.addItem(close)
        case .workspace:
            let newSession = NSMenuItem(title: "New Session", action: #selector(menuNewSession(_:)), keyEquivalent: "")
            newSession.target = self
            newSession.representedObject = node
            menu.addItem(newSession)
            let openSession = NSMenuItem(title: "Open Directory…", action: #selector(menuOpenSession(_:)), keyEquivalent: "")
            openSession.target = self
            openSession.representedObject = node
            menu.addItem(openSession)
            // two different gestures, grouped. "Focus"/"Unfocus" REPLACES the whole set with this
            // workspace and applies the filter — the zoom-to-one — so it reads "Unfocus" only when this
            // workspace is the SOLE member of an applied filter. "Add to Focus"/"Remove from Focus" edits
            // MEMBERSHIP alongside whatever else is marked and never touches the filter flag, so a set is
            // built row by row with the whole tree still on screen.
            let focus = NSMenuItem(title: store.isSoleFocus(node.id) ? "Unfocus" : "Focus",
                                   action: #selector(menuFocusWorkspace(_:)), keyEquivalent: "")
            focus.target = self
            focus.representedObject = node
            menu.addItem(focus)
            let member = store.focusedWorkspaceIDs.contains(node.id)
            let membership = NSMenuItem(title: member ? "Remove from Focus" : "Add to Focus",
                                        action: #selector(menuToggleFocusMembership(_:)), keyEquivalent: "")
            membership.target = self
            membership.representedObject = node
            menu.addItem(membership)
            menu.addItem(.separator())
            // appearance: the system color panel previews live (it's continuous), and Icon… picks an image
            // file (an SF Symbol or emoji is an `rookctl workspace icon` away — there is no public API to
            // enumerate SF Symbols, so a GUI symbol picker would mean hand-maintaining a list).
            // Reset restores the default glyph + theme tint, and is offered only when something is set.
            let color = NSMenuItem(title: "Color…", action: #selector(menuPickWorkspaceColor(_:)), keyEquivalent: "")
            color.target = self
            color.representedObject = node
            menu.addItem(color)
            let icon = NSMenuItem(title: "Icon…", action: #selector(menuPickWorkspaceIcon(_:)), keyEquivalent: "")
            icon.target = self
            icon.representedObject = node
            menu.addItem(icon)
            let workspace = store.workspaces.first(where: { $0.id == node.id })
            // root directory: where new sessions of this workspace open (see AppSettings.resolveNewSessionCwd).
            let setRoot = NSMenuItem(title: "Set Root Directory…", action: #selector(menuSetWorkspaceRoot(_:)), keyEquivalent: "")
            setRoot.target = self
            setRoot.representedObject = node
            menu.addItem(setRoot)
            if workspace?.root != nil {
                let clearRoot = NSMenuItem(title: "Clear Root Directory", action: #selector(menuClearWorkspaceRoot(_:)), keyEquivalent: "")
                clearRoot.target = self
                clearRoot.representedObject = node
                menu.addItem(clearRoot)
            }
            if workspace?.colorHex != nil || workspace?.icon != nil {
                let reset = NSMenuItem(title: "Reset Appearance", action: #selector(menuResetWorkspaceAppearance(_:)),
                                       keyEquivalent: "")
                reset.target = self
                reset.representedObject = node
                menu.addItem(reset)
            }
            menu.addItem(.separator())
            let delete = NSMenuItem(title: "Delete Workspace", action: #selector(menuDeleteWorkspace(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = node
            delete.isEnabled = store.canRemoveWorkspace
            menu.addItem(delete)
        }
        return menu
    }

    private func ownerWorkspaceID(ofSession id: UUID) -> UUID? {
        store.workspaces.first(where: { ws in ws.sessions.contains(where: { $0.id == id }) })?.id
    }

    /// Wraps session batch commands so menu items can carry both the selected ids and a target workspace.
    private final class SessionBatchRequest {
        let sessionIDs: [UUID]
        let targetID: UUID?
        init(sessionIDs: [UUID], targetID: UUID? = nil) {
            self.sessionIDs = sessionIDs
            self.targetID = targetID
        }
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        renameController.beginEditing(node: node)
    }

    @objc private func menuMove(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? SessionBatchRequest, let targetID = request.targetID else { return }
        store.moveSessions(request.sessionIDs, toWorkspace: targetID)
    }

    @objc private func menuClose(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? SessionBatchRequest else { return }
        // pass THIS sidebar's window-local store — a background window's Close must target its own
        // session, not the frontmost window's (which `AppActions.store` would resolve to).
        actions.closeSessions(request.sessionIDs, in: store)
    }

    @objc private func menuClearStatus(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? SessionBatchRequest else { return }
        for id in request.sessionIDs { store.setAgentIndicator(AgentIndicator(), forSession: id) }
    }

    @objc private func menuToggleFlag(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? SessionBatchRequest else { return }
        actions.toggleFlags(request.sessionIDs, in: store)
    }

    @objc private func menuDuplicate(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        // pass THIS sidebar's window-local store, like Close/Flag: a background window's Duplicate must
        // act on its own row, not the frontmost window's session.
        actions.duplicateSession(node.id, in: store)
    }

    @objc private func menuRevealInFinder(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        actions.revealSessionInFinder(node.id, in: store)
    }

    @objc private func menuNewSession(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        // resolve the cwd via the same new-session-directory setting as AppActions.newSession(), so the
        // workspace-row New Session honors it too (workspace root, else home / current cwd / a fixed dir).
        addSession(toWorkspace: node.id, cwd: actions.resolvedNewSessionCwd(inWorkspace: node.id))
    }

    /// Inline "+" button on a workspace row — same action as the right-click "New Session" menu item.
    /// The button carries no workspace id; we derive it from the outline row at click time so reused
    /// cells always target the correct workspace. Internal (not private) because `makeAddSessionButton`
    /// in the RowRendering extension references it via `#selector`.
    @objc func addSessionButtonClicked(_ sender: NSButton) {
        // cancel any pending single-click workspace toggle so clicking "+" doesn't also flip expansion.
        pendingRowToggle?.cancel()
        pendingRowToggle = nil
        guard let outline = outlineView else { return }
        let row = outline.row(for: sender)
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode, node.kind == .workspace else { return }
        addSession(toWorkspace: node.id, cwd: actions.resolvedNewSessionCwd(inWorkspace: node.id))
    }

    @objc private func menuDeleteWorkspace(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        actions.deleteWorkspace(node.id)
    }

    @objc private func menuFocusWorkspace(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        actions.focusWorkspace(node.id)
    }

    /// Adds/removes this workspace from the focus SET without touching the filter flag (the item above is
    /// the replacing zoom-to-one). Membership is re-read at invoke time rather than captured when the
    /// title was built — a menu can outlive the state it was built from.
    @objc private func menuToggleFocusMembership(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        actions.setFocusMembership(node.id, member: !store.focusedWorkspaceIDs.contains(node.id))
    }

    /// "Color…": pick this workspace's sidebar icon color in the system color panel (live preview).
    /// Passes THIS sidebar's window-local store — a background window's row must color its own workspace,
    /// not the frontmost window's (which `AppActions.store` would resolve to), like Close/Flag above.
    @objc private func menuPickWorkspaceColor(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        actions.pickWorkspaceColor(node.id, in: store)
    }

    /// "Icon…": pick an image file (svg/png/jpeg) for this workspace's sidebar icon; it is copied into the
    /// state dir, so it survives the original moving.
    @objc private func menuPickWorkspaceIcon(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        actions.pickWorkspaceIcon(node.id, in: store)
    }

    @objc private func menuResetWorkspaceAppearance(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        actions.resetWorkspaceAppearance(node.id, in: store)
    }

    /// "Set Root Directory…": pick a folder that new sessions of this workspace open in (the control half
    /// is `workspace.root`). Seeds the panel at the current root, else the active session's cwd.
    @objc private func menuSetWorkspaceRoot(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let current = store.workspaces.first(where: { $0.id == node.id })?.root
        panel.directoryURL = DirectoryPanelDefaults.url(paths: current, store.activeSession?.focusedCwd)
        panel.prompt = "Set Root"
        panel.message = "Choose a root directory for new sessions in this workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.setWorkspaceRoot(node.id, path: url.path)
    }

    /// "Clear Root Directory": drop the workspace root so new sessions fall back to the global new-session
    /// directory setting again.
    @objc private func menuClearWorkspaceRoot(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        store.setWorkspaceRoot(node.id, path: nil)
    }

    /// "Open Directory…": pick a folder and add a session rooted there.
    @objc private func menuOpenSession(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        openDirectoryAndAddSession(toWorkspace: node.id)
    }

    /// Adds a session to `workspaceID` at `cwd` and selects it.
    private func addSession(toWorkspace workspaceID: UUID, cwd: String) {
        if let session = store.addSession(toWorkspace: workspaceID, cwd: cwd) {
            // creating + selecting from the sidebar context menu is a user-initiated selection on THIS
            // window's store: note activity so it buys the full idle grace before auto-follow pulls away.
            store.noteUserActivity()
            store.selectSession(session.id)
            actions.focusActiveSession()
        }
    }

    private func openDirectoryAndAddSession(toWorkspace workspaceID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = DirectoryPanelDefaults.url(paths: store.activeSession?.focusedCwd)
        panel.prompt = "Open"
        panel.message = "Choose a directory for the new session"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addSession(toWorkspace: workspaceID, cwd: url.path)
    }
}
