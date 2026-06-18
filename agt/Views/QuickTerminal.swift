import agtCore
import AppKit
import SwiftUI

/// The in-app quick terminal: a single scratch terminal shown as a centered overlay at 90% of
/// the window, on top of the sidebar and terminal. A toolbar button toggles it; clicking the
/// dimmed margin also hides it. Hiding keeps the shell alive — the surface is owned here, not by
/// the overlay view, so it survives the view being removed. Not persisted (fresh each launch).
///
/// App-global like `GhosttyApp.shared`; `agtApp` sets `cwdProvider` so a freshly-spawned quick
/// terminal opens in the active session's directory (home when nothing is selected).
@MainActor @Observable
final class QuickTerminalController {
    static let shared = QuickTerminalController()

    /// Whether the overlay is shown. Observed, so `ContentView` shows/hides the overlay.
    private(set) var isVisible = false

    /// The long-lived quick-terminal surface, created lazily on first show and kept across
    /// hide/show so the shell survives. `@ObservationIgnored`: the overlay pulls it imperatively
    /// (like a session owns its surface), nothing in SwiftUI observes the view itself.
    @ObservationIgnored private var surfaceView: GhosttySurfaceView?

    /// The directory a freshly-created quick terminal spawns its shell in. Read once, when the
    /// surface is created, so the quick terminal keeps its own working directory afterwards.
    @ObservationIgnored var cwdProvider: () -> String = { FileManager.default.homeDirectoryForCurrentUser.path }

    private init() {}

    /// Toolbar-button action: show if hidden, hide if visible.
    func toggle() { isVisible.toggle() }

    func hide() { isVisible = false }

    /// The surface to render in the overlay, created on first use in the active cwd and reused
    /// afterwards. Recreated after the shell exits.
    func surface() -> GhosttySurfaceView {
        if let surfaceView { return surfaceView }
        let view = GhosttySurfaceView(workingDirectory: cwdProvider())
        view.onExit = { [weak self] in self?.handleShellExit() }
        surfaceView = view
        return view
    }

    /// Re-assert first responder on the surface for a short window so focus lands once the
    /// overlay is on-window (a one-shot would race the overlay's layout).
    func focus(attempt: Int = 0) {
        if let surfaceView, let window = surfaceView.window {
            window.makeFirstResponder(surfaceView)
        }
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.focus(attempt: attempt + 1)
        }
    }

    /// The quick-terminal shell exited: hide the overlay and tear down the surface so the next
    /// show spawns a fresh shell (the surface, not the overlay, owns the shell).
    private func handleShellExit() {
        isVisible = false
        surfaceView?.teardown()
        surfaceView = nil
    }
}

/// Hosts the quick-terminal surface in the overlay. Like `TerminalView`, it pulls the
/// long-lived surface from its owner (the controller) rather than creating one, and never frees
/// it on dismantle — hiding the overlay must keep the shell alive.
struct QuickTerminalPane: NSViewRepresentable {
    func makeNSView(context _: Context) -> GhosttySurfaceView {
        let view = QuickTerminalController.shared.surface()
        QuickTerminalController.shared.focus()
        return view
    }

    func updateNSView(_: GhosttySurfaceView, context _: Context) {}

    static func dismantleNSView(_: GhosttySurfaceView, coordinator _: ()) {
        // no-op: the controller owns the surface so it survives hide/show.
    }
}
