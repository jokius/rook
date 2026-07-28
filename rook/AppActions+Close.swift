import rookCore
import AppKit
import Quartz
import SwiftUI

/// The session-close family: the ⌘W dismiss-a-cover-or-close path, the store-scoped sidebar Close, the
/// close confirmation, the undo-grace soft close, and the reopen side (undo / Open Recent). They belong
/// together because every one of them runs through `confirmCloseSession` + `closeSessionAfterConfirmation`
/// and the `closeGraceUndoEnabled` setting. Split out of `AppActions.swift` to keep that hub file under the
/// swiftlint size limit, like the other `AppActions+*` extensions (`+Batch` holds the plural sibling,
/// `+SessionPolicy` the confirm copy + grace duration).
extension AppActions {
    // closes the active session, or dismisses a focus-stealing cover on top of it. returns whether it
    // handled the keystroke, so the ⌘W menu item falls back to closing the window only when nothing was
    // dismissed or closed (no cover, no session). precedence follows the z-order: the quick terminal is
    // window-topmost (works even with no active session), then within a session an overlay sits above the
    // scratch. the overlay is destroyed (closeOverlay, run-once ephemeral) while the quick terminal and
    // scratch are hidden keep-alive; a floating overlay also holds first responder, so ANY overlay is
    // dismissed, not only a full one.
    @discardableResult
    func closeActiveSession() -> Bool {
        // terminal zoom is the window-topmost cover of all: ⌘W dismisses it like the covers below
        // (stepwise — a zoomed quick terminal un-zooms first, the next ⌘W hides it) rather than
        // swallowing the keystroke, and still never mutates hidden session/window state behind it.
        if terminalZoomActive { frontmostTerminalZoom?.clear(); return true }
        // a shown Quick Look preview (file tree) is its own floating panel — ⌘W closes IT first (the Finder
        // gesture), not the session underneath. Gate on the panel being the KEY window so ⌘W in ANOTHER
        // window doesn't swallow a preview opened over a different window's tree (QLPreviewPanel is app-global).
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
           panel.isVisible, panel.isKeyWindow {
            panel.orderOut(nil)
            return true
        }
        if let quick = frontmostQuickTerminal, quick.isVisible { quick.hide(); return true }
        guard let store, let session = store.activeSession else { return false }
        if session.overlayActive { store.closeOverlay(session.id); return true }
        if session.scratchActive { store.toggleScratch(session.id); return true }
        // ⌘W was handled either way — on cancel we return true so the File menu doesn't fall back to
        // closing the whole window.
        guard confirmCloseSession(session) else { return true }
        closeSessionAfterConfirmation(session.id, in: store)
        focusActiveSession()
        return true
    }

    /// Close the session with `id` in `store` from a GUI surface (the sidebar row's Close), honoring the
    /// "Confirm before closing a session" setting. `store` is the caller's own window-local store — a
    /// background window's sidebar must close ITS session, not the frontmost window's — so it is passed in
    /// rather than resolved via the frontmost `activeStore`. The ⌘W/menu/palette path uses
    /// `closeActiveSession` (which acts on the frontmost active session); the control channel's
    /// `session.close` closes directly, without a prompt.
    func closeSession(_ id: UUID, in store: AppStore) {
        guard uiActionsEnabled else { return }
        guard let session = store.session(withID: id) else { return }
        guard confirmCloseSession(session) else { return }
        closeSessionAfterConfirmation(id, in: store)
    }

    /// Undo the latest grace-period session/workspace close in the frontmost window.
    func undoClose() {
        guard uiActionsEnabled else { return }
        guard let store else { return }
        let restored = withAnimation(.easeInOut(duration: 0.16)) {
            store.undoPendingClose()
        }
        guard restored else { return }
        focusActiveSession()
    }

    func openRecentClosed(_ id: RecentClosedItem.ID) {
        guard uiActionsEnabled else { return }
        guard library.reopenRecentClosed(id) else { return }
        focusActiveSession()
    }

    func openLatestRecentClosed() {
        guard uiActionsEnabled else { return }
        guard library.reopenLatestRecentClosed() else { return }
        focusActiveSession()
    }

    func clearRecentClosedItems() {
        library.clearRecentClosedItems()
    }

    /// A native warning confirm before closing `session`, gated by `AppSettings.confirmCloseSession`.
    /// Returns whether to proceed with the close: true immediately (no prompt) when the setting is off,
    /// under an XCUITest launch (a modal would hang the test, like the clear-flagged/quit confirms), or —
    /// with the "only when a session is running an agent" sub-option on — when no coding agent is running
    /// in the session (an empty terminal closes silently). The alert carries a "Don't ask again"
    /// suppression checkbox that turns the master `confirmCloseSession` off.
    private func confirmCloseSession(_ session: Session) -> Bool {
        let settings = settingsModel?.settings
        guard settings?.confirmCloseSession == true,
              !ContentView.shouldBypassCloseConfirmation else { return true }
        // the sub-option narrows the prompt to sessions with a live agent; an empty terminal closes silently.
        if settings?.confirmCloseOnlyRunningAgent == true, session.agentKind == nil { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(session.displayName)”?"
        alert.informativeText = closeConfirmInformativeText(agent: session.agentKind, count: 1)
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { settingsModel?.setConfirmCloseSession(false) }
        return response == .alertFirstButtonReturn
    }

    var closeGraceUndoEnabled: Bool {
        settingsModel?.settings.closeGraceUndoEnabled ?? true
    }

    private func closeSessionAfterConfirmation(_ id: UUID, in store: AppStore) {
        if closeGraceUndoEnabled {
            withAnimation(.easeInOut(duration: 0.16)) {
                _ = store.softCloseSession(id, grace: effectiveCloseGraceSeconds)
            }
        } else {
            store.closeSession(id)
        }
    }
}
