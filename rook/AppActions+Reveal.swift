import rookCore
import AppKit
import SwiftUI

extension AppActions {
    /// Reveal the active session's focused-pane cwd in Finder. Finder gets the directory itself selected
    /// (rather than opening arbitrary terminal output), matching "Reveal in Finder" behavior elsewhere on Mac.
    func revealActiveSessionInFinder() {
        guard let store, let id = store.selectedSessionID else { return }
        revealSessionInFinder(id, in: store)
    }

    var canRevealActiveSessionInFinder: Bool {
        guard let store, let id = store.selectedSessionID else { return false }
        return canRevealSessionInFinder(id, in: store)
    }

    func canRevealSessionInFinder(_ id: UUID, in store: AppStore) -> Bool {
        guard let session = store.session(withID: id) else { return false }
        return DirectoryPanelDefaults.existingDirectoryURL(for: session.focusedCwd) != nil
    }

    /// Reveal a specific session's focused-pane cwd in Finder, scoped to the caller's store so a sidebar
    /// context menu in a background window still acts on the clicked row in that window.
    @discardableResult
    func revealSessionInFinder(_ id: UUID, in store: AppStore) -> Bool {
        guard let session = store.session(withID: id),
              let url = DirectoryPanelDefaults.existingDirectoryURL(for: session.focusedCwd)
        else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }

    /// Open a terminal session rooted at `directory` in the last-active window — the entry point for
    /// `open -a rook <path>` and Finder "Open With ▸ rook" on a folder (`AppDelegate.application(_:open:)`).
    /// Not gated on `uiActionsEnabled`: an external OS-open, like a socket command, must land regardless of a
    /// modal zoom/dashboard. Resolves `store` = the last-active window (what `session.new` also defaults to),
    /// and returns whether it landed so the delegate can retry until a store resolves.
    @discardableResult
    func openSession(atDirectory directory: String) -> Bool {
        guard let store, let workspaceID = store.currentWorkspaceID,
              let session = store.addSession(toWorkspace: workspaceID, cwd: directory) else { return false }
        store.noteUserActivity()
        store.selectSession(session.id)
        focusActiveSession()
        return true
    }
}
