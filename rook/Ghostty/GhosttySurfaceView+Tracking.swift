import AppKit
import GhosttyKit

extension GhosttySurfaceView {
    /// Only the on-screen deck pane tracks the pointer. Every session's surface is eagerly realized, and
    /// AppKit tracking areas ignore SwiftUI's `.opacity(0)` and sibling overlap exactly like the
    /// drag-destination resolution (`deckVisible`) — a hidden surface's `visibleRect` is NOT clipped by an
    /// overlapping sibling, so with `.mouseMoved`/`.cursorUpdate` still armed it receives the SAME move as the
    /// visible pane and races to set the one process-global `NSCursor`. A hidden session cached at a different
    /// mouse shape (a mouse-reporting TUI, or an OSC 22 pointer shape) then flickers over the visible terminal
    /// (issue #225). `setupTrackingArea` installs the area only while `deckVisible`, so a hidden surface's
    /// `mouseMoved`/`cursorUpdate` never fire — which also silences `applyMouseShape`'s `.set()` (guarded on
    /// `pointerInside`, only set from `mouseEntered`). On going off-screen, clear the hover/pointer state a
    /// now-untracked surface would otherwise keep (like `mouseExited`).
    func updatePointerTracking() {
        setupTrackingArea()
        guard !deckVisible else { return }
        pointerInside = false
        if let surface { ghostty_surface_mouse_pos(surface, -1, -1, GHOSTTY_MODS_NONE) }
        lastReportedMousePoint = NSPoint(x: -1, y: -1)
    }

    func setupTrackingArea() {
        if let existing = currentTrackingArea { removeTrackingArea(existing); currentTrackingArea = nil }
        // only the on-screen pane owns the pointer (see `updatePointerTracking`): a hidden deck surface
        // installs NO tracking area, so its `mouseMoved`/`cursorUpdate` never fire and it can't race to set
        // the one process-global cursor — the multi-surface flicker of issue #225.
        guard deckVisible else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        currentTrackingArea = area
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        setupTrackingArea()
    }

    /// Whether this pane owns the pixel under `point` (window coordinates) — no sibling chrome is drawn over
    /// it there. `deckVisible` answers a DIFFERENT question ("am I the on-screen pane?"): tracking areas
    /// ignore sibling overlap (see `updatePointerTracking`), so the on-screen pane keeps receiving `mouseMoved`
    /// under the sidebar's grab handle, an `NSSplitView` divider, or a floating overlay's margin, and
    /// re-asserts its shape into the process-global `NSCursor` on every move — beating chrome that sets the
    /// cursor once on hover entry. Hit-testing resolves ownership the same way the drag that starts in that
    /// band already does, so no per-divider width is guessed and later chrome is covered without touching
    /// this file.
    ///
    /// Declines for CHROME ONLY: a hit landing on any surface — this one, a descendant, or a sibling pane
    /// stacked at the same frame in the eager deck — keeps the pre-existing behavior, so a hit test that
    /// cannot see through the deck can never silence the visible terminal.
    func ownsPointer(at point: NSPoint) -> Bool {
        if overOwnSplitDivider(at: point) { return false }
        guard let hit = window?.contentView?.hitTest(point) else { return true }
        if hit === self || hit.isDescendant(of: self) { return true }
        return hit is GhosttySurfaceView
    }

    /// Whether the point lies in the grab band of the split THIS pane is arranged in — the band that split's
    /// own drag resolves from, so no width is guessed. Asked BEFORE the window-down hit, which cannot see the
    /// divider: every session's split is mounted at the full frame, so a window-down hit reaches whichever
    /// split the deck stacked last, not this pane's — and a hidden entry's split then answers for the
    /// divider column of the session that IS on screen.
    private func overOwnSplitDivider(at pointInWindow: NSPoint) -> Bool {
        guard let split = enclosingSplitView(), let parent = split.superview else { return false }
        return split.hitTest(parent.convert(pointInWindow, from: nil)) === split
    }

    /// `ownsPointer(at:)` for the callers with no event in hand (`applyMouseShape`, activation), reading the
    /// pointer live rather than from possibly-stale state.
    func ownsPointer() -> Bool {
        guard let window else { return true }
        return ownsPointer(at: window.mouseLocationOutsideOfEventStream)
    }
}
