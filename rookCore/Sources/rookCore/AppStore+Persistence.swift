import Foundation

/// Snapshot capture + restore, and the debounced/immediate save paths. Split out of `AppStore.swift` to keep
/// that file under the swiftlint size limit; behavior is unchanged.
extension AppStore {
    // MARK: - Persistence

    /// Builds a `Snapshot` value of the current tree. Each session captures its
    /// live `currentCwd` (or `initialCwd` if no PWD report has arrived). Runs on
    /// `@MainActor`; the resulting value is `Sendable` and safe to hand to a writer.
    public func snapshot() -> Snapshot {
        let workspaceSnapshots = workspaces.map { workspace in
            let sessions = workspace.sessions.map(sessionSnapshot)
            // only a collapsed workspace writes the flag; an expanded one omits it (nil) so an all-expanded
            // tree serializes identically to a legacy snapshot.
            return WorkspaceSnapshot(id: workspace.id, name: workspace.name, sessions: sessions,
                                     collapsed: workspace.isExpanded ? nil : true, colorHex: workspace.colorHex,
                                     icon: workspace.icon)
        }
        return Snapshot(selectedSessionID: selectedSessionID, workspaces: workspaceSnapshots,
                        sidebarWidth: sidebarWidth, fileTreeWidth: fileTreeWidth,
                        sidebarVisible: sidebarVisible, sidebarMode: sidebarMode,
                        focusedWorkspaceID: focusedWorkspaceID, sessionRecency: sessionRecency.items)
    }

    /// Rebuilds the tree from a snapshot: fresh `Session`s (surfaces and shells
    /// spawn lazily on first display) keyed by the persisted ids so the restored
    /// `selectedSessionID` still resolves. Replaces the current state wholesale.
    ///
    /// Deliberately does NOT call `save()`: it loads what was just read from disk,
    /// so re-persisting it would be a pointless write (and the only mutator that
    /// skips `save()` for that reason). If the persisted `selectedSessionID` points
    /// at a session that no longer exists, it is cleared to keep selection valid.
    public func restore(from snapshot: Snapshot) {
        // fold workspaces sharing an id into the first occurrence, and keep only the first snapshot of any
        // repeated session id, wherever it sits: a file written by a build that could duplicate either
        // stays unreachable past the first match otherwise, and re-saves the corruption.
        var seenSessionIDs: Set<UUID> = []
        workspaces = snapshot.workspaces.reduce(into: [Workspace]()) { restored, workspaceSnapshot in
            let sessions = workspaceSnapshot.sessions
                .filter { seenSessionIDs.insert($0.id).inserted }
                .map(session(from:))
            if let existing = restored.firstIndex(where: { $0.id == workspaceSnapshot.id }) {
                restored[existing].sessions.append(contentsOf: sessions)
                return
            }
            // absent/nil collapsed → expanded (back-compat with snapshots written before the field existed).
            restored.append(Workspace(id: workspaceSnapshot.id, name: workspaceSnapshot.name, sessions: sessions,
                                      isExpanded: !(workspaceSnapshot.collapsed ?? false),
                                      colorHex: workspaceSnapshot.colorHex, icon: workspaceSnapshot.icon))
        }
        // clamp on restore (not just nil-default) so a corrupt or hand-edited snapshot can't drive an
        // out-of-range frame width; the drag path clamps to the same bounds.
        sidebarWidth = min(AppStore.sidebarWidthMax, max(AppStore.sidebarWidthMin, snapshot.sidebarWidth ?? AppStore.sidebarWidthDefault))
        fileTreeWidth = min(AppStore.fileTreeWidthMax, max(AppStore.fileTreeWidthMin, snapshot.fileTreeWidth ?? AppStore.fileTreeWidthDefault))
        sidebarVisible = snapshot.sidebarVisible ?? true
        sidebarMode = snapshot.sidebarMode ?? .tree
        // a stale focus id (its workspace not in the restored tree) is harmless — `visibleWorkspaces`
        // falls back to the full tree — so restore it verbatim; nil stays unfocused.
        focusedWorkspaceID = snapshot.focusedWorkspaceID
        if let id = snapshot.selectedSessionID, session(withID: id) == nil {
            selectedSessionID = nil
        } else {
            selectedSessionID = snapshot.selectedSessionID
        }
        replaceSidebarSelection(with: selectedSessionID)
        // re-seed the Ctrl-Tab order from the persisted list (dropping ids not in the restored
        // tree) so the switcher works right after relaunch; the restored selection floats to the
        // front, keeping the "previous session" slot truthful.
        let restoredIDs = Set(workspaces.flatMap(\.sessions).map(\.id))
        sessionRecency = RecencyStack(items: (snapshot.sessionRecency ?? []).filter { restoredIDs.contains($0) })
        recordRecency()
    }

    /// Persists the current state eagerly. Called after every structural mutation and on
    /// terminate. Cancels any pending debounced save first, so a `save()` (incl. the
    /// quit-flush) always writes the latest snapshot and a stale scheduled write can't
    /// fire afterward. A write failure is logged and swallowed — a transient disk error
    /// must not bring down the model.
    public func save() {
        saveDebouncer.cancel()
        do {
            try persistence.save(snapshot())
        } catch {
            log("save failed: \(error)")
        }
    }

    /// Debounces a `save()` ~0.3 s out, coalescing the rapid selection/font writes. Used by
    /// `selectSession`/`setFontSize` and `setWorkspaceColor` (the color panel drags continuously);
    /// structural mutations call `save()` immediately. A `save()` (or the quit-flush) cancels the pending
    /// schedule, so the latest state is always captured. Not `private`: `AppStore+Appearance` needs it.
    func scheduleSave() {
        saveDebouncer.schedule(after: AppStore.saveDebounceInterval) { [weak self] in
            self?.save()
        }
    }

    /// Drops any pending debounced save WITHOUT writing — unlike `save()`, which cancels then writes.
    /// Used when the owning window is being deleted (`WindowLibrary.removeWindow`): the per-window file
    /// is about to be removed, so a save scheduled by a just-before-delete selectSession/setFontSize
    /// must be dropped rather than flushed, else it would fire after the file is deleted and re-create
    /// it as an orphan.
    public func cancelPendingSave() {
        saveDebouncer.cancel()
    }

    private func log(_ message: @autoclosure () -> String) {
        NSLog("rook: %@", message())
    }
}
