import rookCore
import AppKit
import SwiftUI

extension AppActions {
    /// Duplicates a session — a fresh shell in the source's directory, placed right after it. Scoped to the
    /// caller's store (like the other sidebar row actions) so a background window's context menu acts on its
    /// own row, not the frontmost store's session. `AppStore.duplicateSession` carries the directory-only
    /// contract; this adds the same select + focus the sidebar's New Session does. Returns nothing (matching
    /// `newSession`/`openDirectory`) — the control path calls `store.duplicateSession` directly for the id.
    func duplicateSession(_ id: UUID, in store: AppStore) {
        guard let session = store.duplicateSession(id) else { return }
        // creating + selecting a session is a user-initiated selection: note activity so it buys the full
        // idle grace before auto-follow can pull the selection away from the just-made session.
        store.noteUserActivity()
        store.selectSession(session.id)
        focusActiveSession()
    }

    /// Duplicate the ACTIVE session — the active-session entry point for the menu bar, the ⌃⇧P command
    /// palette, and a `duplicate_session` keymap binding, mirroring `renameActiveSession()` vs the sidebar's
    /// row-scoped `duplicateSession(_:in:)`. Acts on the frontmost window's store and its selected session.
    func duplicateActiveSession() {
        guard uiActionsEnabled else { return }
        guard let store, let id = store.selectedSessionID else { return }
        duplicateSession(id, in: store)
    }
}
