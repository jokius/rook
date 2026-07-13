import rookCore
import AppKit
import SwiftUI

extension AppActions {
    /// Open (or re-target) the active session's Markdown preview panel on `path`. The entry point for a
    /// `.preview` link click in the terminal, a cross-link inside a rendered document, and the control
    /// channel. `path` is expected absolute and already validated by `LinkPolicy` / the control arm.
    func openMarkdown(_ path: String) {
        guard let store, let session = store.activeSession else { return }
        store.openMarkdown(path, forSession: session.id)
    }

    /// Close the active session's preview panel (the header's ✕ and the View menu).
    func closeMarkdown() {
        guard let store, let session = store.activeSession else { return }
        store.closeMarkdown(session.id)
        // the panel takes first responder (text selection, scrolling), so hand keyboard focus back to the
        // terminal rather than leaving it stranded on the column that just went away — same as the file tree.
        focusActiveSession()
    }

    /// Toggle the preview panel for the View menu / keybind: close it when open. There is no file to open
    /// from a bare menu invocation — the panel is opened by clicking a Markdown link — so a closed panel with
    /// nothing to show stays closed.
    func toggleMarkdown() {
        guard let store, let session = store.activeSession, session.markdownPath != nil else { return }
        closeMarkdown()
    }
}
