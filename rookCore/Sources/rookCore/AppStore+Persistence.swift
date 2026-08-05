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
                                     icon: workspace.icon, root: workspace.root)
        }
        // the marked set in TREE order, so the on-disk list is deterministic rather than following the
        // Set's hash order; an unmarked store omits both focus keys, keeping its file identical to one
        // written before the set existed. Neither legacy focus key is ever written back.
        let focusIDs = workspaces.map(\.id).filter(focusedWorkspaceIDs.contains)
        return Snapshot(selectedSessionID: selectedSessionID, workspaces: workspaceSnapshots,
                        sidebarWidth: sidebarWidth, fileTreeWidth: fileTreeWidth, markdownWidth: markdownWidth,
                        sidebarVisible: sidebarVisible, sidebarMode: sidebarMode,
                        focusedWorkspaceIDs: focusIDs.isEmpty ? nil : focusIDs,
                        focusEnabled: focusEnabled ? true : nil,
                        sessionRecency: sessionRecency.items)
    }

    /// Rebuilds the tree from a snapshot: fresh `Session`s (surfaces and shells
    /// spawn lazily on first display) keyed by the persisted ids so the restored
    /// `selectedSessionID` still resolves. Replaces the current state wholesale.
    ///
    /// Deliberately does NOT call `save()`: it loads what was just read from disk,
    /// so re-persisting it would be a pointless write (and the only mutator that
    /// skips `save()` for that reason). The closing `reselectIfSelectionHidden` is
    /// the exception — when it repairs a selection the restored filter/mode strands,
    /// its `selectSession` schedules a save, and THAT one is worth writing.
    /// If the persisted `selectedSessionID` points
    /// at a session that no longer exists, it is cleared to keep selection valid.
    ///
    /// `launchRestore` marks an APP-BOOTSTRAP restore and is the ONLY thing that arms a persisted
    /// `session.restore` override for this launch (`Session.armPendingRestoreOverrides()`). It defaults to
    /// false because this method has RUNTIME callers too: reopening a closed window mid-process reloads its
    /// store through here, and that must not execute anything.
    public func restore(from snapshot: Snapshot, launchRestore: Bool = false) {
        freshWorkspaceID = nil // live create-time state, never restored from disk
        // fold workspaces sharing an id into the first occurrence, and keep only the first snapshot of any
        // repeated session id, wherever it sits: a file written by a build that could duplicate either
        // stays unreachable past the first match otherwise, and re-saves the corruption.
        var seenSessionIDs: Set<UUID> = []
        workspaces = snapshot.workspaces.reduce(into: [Workspace]()) { restored, workspaceSnapshot in
            let sessions = workspaceSnapshot.sessions
                .filter { seenSessionIDs.insert($0.id).inserted }
                .map(session(from:))
            if launchRestore { for session in sessions { session.armPendingRestoreOverrides() } }
            if let existing = restored.firstIndex(where: { $0.id == workspaceSnapshot.id }) {
                restored[existing].sessions.append(contentsOf: sessions)
                return
            }
            // absent/nil collapsed → expanded (back-compat with snapshots written before the field existed).
            restored.append(Workspace(id: workspaceSnapshot.id, name: workspaceSnapshot.name, sessions: sessions,
                                      isExpanded: !(workspaceSnapshot.collapsed ?? false),
                                      colorHex: workspaceSnapshot.colorHex, icon: workspaceSnapshot.icon,
                                      root: workspaceSnapshot.root))
        }
        // clamp on restore (not just nil-default) so a corrupt or hand-edited snapshot can't drive an
        // out-of-range frame width; the drag path clamps to the same bounds.
        sidebarWidth = min(AppStore.sidebarWidthMax, max(AppStore.sidebarWidthMin, snapshot.sidebarWidth ?? AppStore.sidebarWidthDefault))
        fileTreeWidth = min(AppStore.fileTreeWidthMax, max(AppStore.fileTreeWidthMin, snapshot.fileTreeWidth ?? AppStore.fileTreeWidthDefault))
        markdownWidth = min(AppStore.markdownWidthMax, max(AppStore.markdownWidthMin, snapshot.markdownWidth ?? AppStore.markdownWidthDefault))
        sidebarVisible = snapshot.sidebarVisible ?? true
        sidebarMode = snapshot.sidebarMode ?? .tree
        // both focus fields, so a filter an involuntary jump switched off can still be re-applied after the
        // relaunch; members absent from the rebuilt tree are pruned there (see `restoreFocus(from:)`).
        restoreFocus(from: snapshot)
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
        // LAST, after the recency stack is re-seeded: a restored filter/mode can hide the restored
        // selection, and the repair picks MRU — run any earlier and it would find an empty stack and fall
        // back to the positional first row.
        reselectIfSelectionHidden()
    }

    /// Persists the current state eagerly. Called after every structural mutation and on
    /// terminate. Cancels any pending debounced save first, so a `save()` (incl. the
    /// quit-flush) always writes the latest snapshot and a stale scheduled write can't
    /// fire afterward. A write failure is logged and swallowed — a transient disk error
    /// must not bring down the model.
    public func save() {
        saveChecked()
    }

    /// `save()` that REPORTS whether the write landed instead of swallowing the failure, for a caller whose
    /// acknowledgement must not outrun the disk. `setRestoreCommand` is the one today: its payload is an
    /// arbitrary shell line re-typed on every launch, so a "cleared" ack that never reached disk would leave
    /// the old command armed forever. `save()` is this with the result discarded, so the two can't drift.
    @discardableResult
    func saveChecked() -> Bool {
        saveDebouncer.cancel()
        do {
            try persistence.save(snapshot())
            return true
        } catch {
            log("save failed: \(error)")
            return false
        }
    }

    // MARK: - Per-session restore-command override

    /// Sets a pane's PERSISTED restore-command override, the single mutation point for the control
    /// channel's `session.restore`. Tri-state `value`: nil = no override (auto-capture), `""` = pinned to
    /// nothing (a plain shell), `"cmd"` = run that shell line on the next launch. Persists IMMEDIATELY —
    /// the override must survive a SIGKILL, or a hook's write is lost before the next launch reads it.
    /// Idempotent: an unchanged value writes nothing. No-op for an unknown id.
    ///
    /// It deliberately does NOT touch the pending slots: a write during this run must not execute during
    /// this run. Only an app-bootstrap restore arms them (`restore(from:launchRestore: true)`), and only the
    /// surface factories consume them. `.scratch` is rejected at the command layer (the scratch terminal is
    /// never restored), so it is a `false` here rather than a silent write to a nonexistent slot.
    ///
    /// Returns whether the requested value is now on disk, so the caller can refuse to acknowledge a write
    /// that never landed — unlike the rest of the store, which mutates and lets `save()` swallow its error.
    /// A failed save is ROLLED BACK in memory, both so the value keeps matching disk and so the
    /// unchanged-value guard can't swallow the retry.
    @discardableResult
    public func setRestoreCommand(_ value: String?, pane: StatusPane, forSession id: UUID) -> Bool {
        guard let session = session(withID: id) else { return false }
        let field: ReferenceWritableKeyPath<Session, String?>
        switch pane {
        case .left: field = \.restoreCommand
        case .right: field = \.splitRestoreCommand
        case .scratch: return false
        }
        let previous = session[keyPath: field]
        guard previous != value else { return true }
        session[keyPath: field] = value
        guard saveChecked() else {
            session[keyPath: field] = previous
            return false
        }
        return true
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
