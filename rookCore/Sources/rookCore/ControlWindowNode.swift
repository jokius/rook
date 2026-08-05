import Foundation

// The `window.list` wire shape: an open window's frame plus the per-window state a script reads back
// after driving `window.move`/`window.resize`/`window.zoom`/`window.fullscreen`/`window.minimize`.
// Split out of `ControlProtocol.swift`, which reached the 1000-line file budget; the window family is
// the seam nothing else in the protocol reaches into.

/// An open window's on-screen frame, in the SAME coordinate system `window.move`/`window.resize` accept,
/// so a read-then-restore round-trips: `x`/`y` are the top-left relative to `display`'s top-left (y down),
/// `width`/`height` the frame size in points, `display` the index into the screen list. The read side of
/// the write-only `window.move`/`window.resize`.
public struct ControlWindowFrame: Codable, Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let display: Int

    public init(x: Int, y: Int, width: Int, height: Int, display: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.display = display
    }
}

/// A window as projected into the `window.list` response. `open` is whether its on-screen window is
/// up; `active` is whether it is the frontmost window.
public struct ControlWindowNode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let open: Bool
    public let active: Bool
    /// The window's auto-follow-blocked timeout in milliseconds, or nil when disabled (omitted from the
    /// JSON), as of the last cache refresh — `window.list` is answered from a nonisolated fast path, so a
    /// just-changed setting may lag until the next command. Acceptable because the config rarely changes;
    /// the live `idleMs` is deliberately kept off `window.list` (tree-only) for exactly this reason.
    public let autoFollowMs: Int?
    /// Whether this window's sidebar is currently visible, or nil for a CLOSED window with no live store
    /// (omitted from the JSON) — read from the open window's store, mirroring `autoFollowMs`. The read side
    /// of the write-only `sidebar` command, per window.
    public let sidebarVisible: Bool?
    /// The window's current on-screen frame (position + size + display), or nil for a CLOSED window with no
    /// live NSWindow (omitted from the JSON). The read side of `window.move`/`window.resize` — record it,
    /// resize/move the window, then restore the exact frame. Read live app-side; it rides the window cache,
    /// which is refreshed on window move/resize/zoom/fullscreen (`ControlServer` observes the NSWindow
    /// notifications), so a hand-drag or GUI toggle is reflected without needing another command.
    public let geometry: ControlWindowFrame?
    /// Whether the window is in native macOS full screen, or nil for a CLOSED window (omitted from the
    /// JSON). The read side of the write-only `window.fullscreen` toggle, so a script can make the toggle
    /// idempotent (only enter/exit when needed). Read live app-side; like `geometry` it rides the cache.
    public let fullscreen: Bool?
    /// Whether the window is zoomed (maximized-to-screen, NOT full screen), or nil for a CLOSED window
    /// (omitted from the JSON). The read side of the write-only `window.zoom` toggle. Read live app-side.
    public let zoomed: Bool?
    /// Whether the window is minimized to the Dock, or nil for a CLOSED window (omitted from the JSON).
    /// The read side of `window.minimize`, so a script can skip a redundant minimize or restore the set
    /// of windows it put away. Read live app-side; like `geometry` it rides the cache, refreshed on the
    /// NSWindow miniaturize/deminiaturize notifications so ⌘M or a Dock click is reflected too. A
    /// minimized window still reports its `geometry` (the frame it will come back to).
    public let minimized: Bool?

    public init(id: String, name: String, open: Bool, active: Bool, autoFollowMs: Int? = nil,
                sidebarVisible: Bool? = nil, geometry: ControlWindowFrame? = nil,
                fullscreen: Bool? = nil, zoomed: Bool? = nil, minimized: Bool? = nil) {
        self.id = id
        self.name = name
        self.open = open
        self.active = active
        self.autoFollowMs = autoFollowMs
        self.sidebarVisible = sidebarVisible
        self.geometry = geometry
        self.fullscreen = fullscreen
        self.zoomed = zoomed
        self.minimized = minimized
    }
}
