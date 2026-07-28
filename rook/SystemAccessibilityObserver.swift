import AppKit
import Foundation

/// Bridges macOS accessibility display-option changes (Reduce Motion / Reduce Transparency) into rook's
/// app-local appearance channel, so a live system flip re-dresses the app without a relaunch.
///
/// The gotcha this file exists for: AppKit posts that notification on `NSWorkspace.shared.notificationCenter`,
/// NOT `NotificationCenter.default` — a plain default-center observer simply never fires.
///
/// It reposts `.rookAppearanceChanged` rather than opening a channel of its own, because every AppKit
/// consumer that cares already re-asserts on that one, idempotently: `WindowAccessor` →
/// `WindowAppearance.sync` (re-resolves Reduce Transparency for the window's opacity/blur) and the sidebar
/// Coordinator → `reapplyStatusRows()` (re-resolves Reduce Motion on the status glyph). SwiftUI consumers
/// need nothing from here — they read `\.accessibilityReduceMotion` / `\.accessibilityReduceTransparency`
/// and refresh themselves.
///
/// The settled values are read straight off `NSWorkspace` at handling time, so the notification carries no
/// payload and no initial post is needed: consumers resolve the current setting on their first render /
/// window attachment anyway.
@MainActor
final class SystemAccessibilityObserver {
    /// Held only to keep `start()` idempotent. No deregistration: the observer is a `@State` on the `App`,
    /// so it lives for the whole process — same as `SystemAppearanceObserver`.
    private var displayOptionsObserver: NSObjectProtocol?

    /// Register the observer. Idempotent — the scene `.task` runs once per window, so guard against
    /// stacking registrations, like `SystemAppearanceObserver.start()`.
    func start() {
        guard displayOptionsObserver == nil else { return }
        let workspace = NSWorkspace.shared
        displayOptionsObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            // object nil, NOT `workspace`: the SDK documents only that this posts to the workspace
            // notification center and says nothing about the sender, so narrowing by object would
            // silently never fire if AppKit posts it with none.
            object: nil, queue: .main
        ) { _ in
            // NotificationCenter's block is @Sendable even with a main queue, so HOP rather than assume
            // isolation (the GhosttyCallbacks convention). Load-bearing: `.rookAppearanceChanged` has
            // synchronous @MainActor observers — a post runs them on the CALLER's thread.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .rookAppearanceChanged, object: nil)
            }
        }
    }
}
