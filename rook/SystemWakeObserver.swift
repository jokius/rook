import AppKit
import Foundation

/// Bridges the macOS display-wake notification into rook's app-local notification center, the way
/// `SystemAccessibilityObserver` bridges accessibility changes: AppKit posts it on
/// `NSWorkspace.notificationCenter`, NOT the default center surfaces observe.
///
/// Why any of this exists: `ghostty_surface_new` returns NULL for the whole time the display is asleep
/// (measured: 21 consecutive failures over 40s), so a session created by a scheduled job in that window
/// realizes no surface and its `--command` never runs. Nothing retries, because SwiftUI runs no layout for
/// an off-display window — `updateNSView` never fires — so the pane stays dead long after the machine is
/// usable again. Creation starts succeeding the instant the displays wake, with the screen still LOCKED,
/// so wake is the earliest correct moment to re-attempt and no unlock hook is needed.
@MainActor
final class SystemWakeObserver {
    /// Held for BOTH jobs: it keeps `start()` idempotent (like `SystemAccessibilityObserver`'s token) and it
    /// is what `deinit` withdraws — unlike that sibling, which registers for the app's lifetime and never
    /// deregisters. The tests depend on the withdrawal to keep one case's observer out of the next one.
    private var wakeObserver: NSObjectProtocol?

    /// Register the observer. Idempotent — the scene `.task` runs once per window, so guard against
    /// stacking registrations, like `SystemAccessibilityObserver.start()`.
    func start() {
        guard wakeObserver == nil else { return }
        let workspace = NSWorkspace.shared
        wakeObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { _ in
            // NotificationCenter's block is @Sendable even with a main queue, so HOP rather than assume
            // isolation — the same convention `SystemAccessibilityObserver` follows.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .rookScreensDidWake, object: nil)
            }
        }
    }

    isolated deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}
