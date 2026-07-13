import rookCore
import AppKit
import SwiftUI

extension AppActions {
    /// Whether the frontmost window's dashboard grid overlay is open. Like a zoom or an open palette, the
    /// dashboard is modal and its key-catcher owns first responder, so `focusActiveSession` must not grab
    /// the active session's surface while it is up (that surface is a view-only grid cell).
    var dashboardActive: Bool {
        DashboardControllerRegistry.shared.controller(for: library.activeWindowID)?.isOpen == true
    }

    /// Whether the dashboard overlay is open in the window OWNING this session — the session-scoped twin of
    /// the frontmost `dashboardActive`, mirroring `terminalZoomActive(for:)`. The right gate for
    /// `focusSplitPane`, whose callers (⌃1/⌃2, ⌘D, the control `session.focus --pane`) can target a session
    /// in ANY window: while that window's dashboard is up its key-catcher owns first responder, and a
    /// NON-member deck surface behind the modal is NOT view-only, so grabbing first responder for it would
    /// steal keystrokes from the catcher into a hidden terminal. Gates on the session's window, not the
    /// frontmost one, for the same cross-window reason as `terminalZoomActive(for:)`.
    func dashboardActive(for session: Session) -> Bool {
        guard let windowID = library.windowID(forSession: session.id) else { return false }
        return DashboardControllerRegistry.shared.controller(for: windowID)?.isOpen == true
    }

    /// Move first responder to the split (right) pane on open, or the primary on close.
    /// Re-asserts over a short window because the split surface materializes a beat after the
    /// toggle and the HSplitView collapse churns the primary view. While a full-coverage surface
    /// (scratch or overlay) is up, the requested pane is hidden beneath it, so keep first responder on
    /// the visible `topmostSurface` instead — the caller has already set `splitFocused`, so the correct
    /// pane shows once the cover is dismissed.
    func focusSplitPane(_ session: Session, wantSplit: Bool, attempt: Int = 0, generation: Int? = nil) {
        // each fresh call SUPERSEDES any in-flight retry loop in the SAME WINDOW. without this, two calls
        // with opposite targets (focus-left then focus-right) each run their own 12x30ms
        // `makeFirstResponder` loop concurrently and ping-pong first responder between the panes for
        // ~400ms - both surfaces redraw on every flip, the split-focus flicker. the counter is keyed by the
        // owning WINDOW: one NSWindow has one first responder, so a newer focus op anywhere in it supersedes
        // an older loop there (last-focus-wins), while different windows stay independent (never cancel each
        // other's still-materializing retries). the surviving loop still re-asserts through the
        // split-materialize / reparent churn (a lone loop's re-asserts are no-ops once its target is first
        // responder), so the retry keeps its original purpose.
        let gen: Int
        let scope = library.windowID(forSession: session.id) ?? session.id // fall back to session id when windowless
        if let generation {
            guard generation == focusGeneration[scope] else { return } // superseded by a newer op in this window
            gen = generation
        } else {
            gen = (focusGeneration[scope] ?? 0) + 1
            focusGeneration[scope] = gen
        }
        // gate on the SESSION's window, not the frontmost one: this path is cross-window (the control
        // channel focuses sessions in background windows), where the frontmost window's zoom is irrelevant.
        if terminalZoomActive(for: session) { return }
        if dashboardActive(for: session) { return }
        // the quick terminal is a window-level cover above the session; while it's up it owns focus, so
        // don't move first responder to a pane behind it (its own hide restores the session). The caller
        // has already set `splitFocused`, so the right pane shows once the quick terminal is dismissed.
        if frontmostQuickTerminal?.isVisible == true { return }
        let target: (any TerminalSurface)? = (session.overlayActive || session.scratchActive)
            ? session.topmostSurface
            : (wantSplit ? session.splitSurface : session.surface)
        if let view = target as? GhosttySurfaceView, let window = view.window {
            window.makeFirstResponder(view)
        }
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.focusSplitPane(session, wantSplit: wantSplit, attempt: attempt + 1, generation: gen)
        }
    }
}
