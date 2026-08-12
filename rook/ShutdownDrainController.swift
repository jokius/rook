import AppKit
import rookCore

/// Quit-time agent drain: writes the flag the installed `PostToolUse` hook reads, then waits a bounded
/// time for every mid-turn agent to leave `active` before letting the termination proceed.
///
/// Lives outside `AppDelegate` because it owns real state (a timer, a sheet, a file) with a lifetime of
/// its own; the delegate only starts it and is called back.
///
/// The wait rides `.terminateLater` rather than a blocking `runModal`, which matters twice over: the
/// runloop keeps spinning, so the control socket keeps serving the `session.status completed` that the
/// agents' own `Stop` hooks send — that is what lets the drain finish EARLY — and a logout is no longer
/// parked on a modal nobody asked for.
///
/// One-shot by construction: `finished` latches, and a `.terminateLater` is only ever answered once.
@MainActor
final class ShutdownDrainController {
    private var timer: Timer?
    private var alert: NSAlert?
    private var flagPath: String?
    private var deadline: Date?
    private var statusProvider: (@MainActor () -> [AgentStatus])?
    private var finished = false

    /// Start the drain. Returns false when there is nothing to wait for, in which case the caller must
    /// terminate normally and this controller stays untouched.
    ///
    /// `socketPath` anchors the flag file; `statusProvider` is re-read on every tick rather than captured
    /// once, because the whole point is to notice agents going idle while we wait.
    func begin(socketPath: String, graceSeconds: TimeInterval,
               statusProvider: @escaping @MainActor () -> [AgentStatus],
               presentingWindow: NSWindow?) -> Bool {
        guard ShutdownDrain.shouldDrain(statuses: statusProvider(), graceSeconds: graceSeconds) else {
            return false
        }
        self.statusProvider = statusProvider
        let path = ShutdownDrain.flagPath(socketPath: socketPath)
        flagPath = path
        let seconds = Int(graceSeconds.rounded())
        try? ShutdownDrain.flagMessage(seconds: seconds).write(toFile: path, atomically: true,
                                                              encoding: .utf8)
        deadline = Date().addingTimeInterval(graceSeconds)
        present(on: presentingWindow, activeCount: ShutdownDrain.activeCount(statusProvider()),
                secondsLeft: seconds)
        // 0.25s: fast enough that an agent finishing right away is noticed as such, cheap enough that a
        // 30s budget is still only ~120 no-op ticks. Same `Timer` + `MainActor.assumeIsolated` shape as
        // `AgentMonitor.start()` (`rook/Ghostty/AgentMonitor.swift:50`) — the house idiom for a main-actor
        // repeating timer under strict concurrency.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common`, NOT the default mode: a sheet puts the runloop in modal-panel mode, where a
        // `scheduledTimer` (default mode only) would stop firing and the drain would hang until the user
        // pressed Close Now.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        return true
    }

    private func tick() {
        guard !finished, let deadline, let statusProvider else { return }
        let activeCount = ShutdownDrain.activeCount(statusProvider())
        let secondsLeft = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
        if activeCount == 0 || secondsLeft == 0 {
            finish()
            return
        }
        alert?.informativeText = ShutdownDrain.waitingMessage(activeCount: activeCount,
                                                              secondsLeft: secondsLeft)
    }

    /// Stop waiting and let the termination proceed. Idempotent — the Close Now button and the timer can
    /// both reach it, and replying twice to one `.terminateLater` is a hard AppKit error.
    func finish() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        clearFlag()
        if let alert, let sheet = alert.window.sheetParent {
            sheet.endSheet(alert.window)
        }
        alert = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func clearFlag() {
        if let flagPath { try? FileManager.default.removeItem(atPath: flagPath) }
        flagPath = nil
    }

    /// Remove a flag left behind by a hard-killed previous run: a stale one would make every `PostToolUse`
    /// hook exit 2 forever, so launch clears it unconditionally. Same reasoning as `ControlServer`'s
    /// unlink-before-bind.
    static func clearStaleFlag(socketPath: String) {
        try? FileManager.default.removeItem(atPath: ShutdownDrain.flagPath(socketPath: socketPath))
    }

    private func present(on window: NSWindow?, activeCount: Int, secondsLeft: Int) {
        // No window is a degenerate case (every window closed), not a reason to skip the drain: the sheet
        // is indication, the timer is the mechanism.
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Letting agents wrap up…"
        alert.informativeText = ShutdownDrain.waitingMessage(activeCount: activeCount,
                                                             secondsLeft: secondsLeft)
        alert.addButton(withTitle: "Close Now")
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }
}
