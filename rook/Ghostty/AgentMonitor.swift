import AppKit
import Foundation
import rookCore

/// AgentMonitor keeps each session's `agentKind` in step with what its focused pane is actually running, so
/// the sidebar row can show the agent's logo (Claude / OpenAI) instead of the terminal glyph. It reuses the
/// restore-running-command capture — `GhosttySurfaceView.foregroundPid()` (libghostty) → `ForegroundProcess`
/// (`sysctl`) → the host-free `AgentKind.classify` — and owns nothing but the sweep.
///
/// **This is the app's only repeating timer, and it is a deliberate exception** to the demand-driven rule
/// (rendering coalesces libghostty wakeups; there is no poll loop anywhere else). libghostty exposes no
/// child-SPAWN action — the closest, `GHOSTTY_ACTION_COMMAND_FINISHED`, fires only when a command ENDS and
/// carries no pid — so an agent STARTING is unobservable and there is nothing to subscribe to. The sweep is
/// made cheap instead of frequent: the per-session pid cache means the steady state is one
/// `ghostty_surface_foreground_pid` read per open session per tick, and the `sysctl` runs only when a pane's
/// foreground pid actually changed (a shell forks a fresh pid per command, so an unchanged pid cannot have
/// changed its argv).
@MainActor
final class AgentMonitor {
    static let shared = AgentMonitor()

    /// The window library whose open sessions are swept. Weak, set at launch by `rookApp`, like
    /// `DockBadgeController.library`.
    weak var library: WindowLibrary?

    /// How often the foreground process of every open session is re-read. Coarse on purpose: the icon is
    /// ambient information, and an agent's own OSC title lands first anyway.
    private static let interval: TimeInterval = 2

    private var timer: Timer?

    /// Last observed foreground pid + its classification, keyed by session id. Rebuilt from the live walk on
    /// every sweep, so a closed session's entry drops out instead of leaking.
    private var cache: [UUID: (pid: pid_t, kind: AgentKind?)] = [:]

    /// Begin sweeping. Idempotent — the scene `.task` runs once per window, so a second call must not stack a
    /// second timer (it just re-sweeps). Called from the scene `.task` alongside `DockBadgeController.start()`.
    func start() {
        guard timer == nil else { return sweep() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        sweep()
    }

    /// Stop sweeping — called from `applicationWillTerminate`, like `controlServer.stop()`.
    func stop() {
        timer?.invalidate()
        timer = nil
        cache.removeAll()
    }

    /// Re-read every open session's focused-pane foreground process and update `Session.agentKind`.
    ///
    /// Holds NOTHING across ticks but the pid cache (a plain value): the sessions and their surfaces are
    /// re-walked each sweep, so a session closed — or a surface freed by `destroySurface` — between ticks is
    /// simply absent, and an unrealized surface (the eager deck's `pendingSurfaceCreation`) reads a nil pid.
    ///
    /// The `!=` guard is MANDATORY, not a nicety: `@Observable` notifies on every set, equal or not, so an
    /// unguarded write would re-run the sidebar's `updateNSView` + reconcile diff on every tick, forever.
    private func sweep() {
        guard let library else { return }
        let shellBasename = ProcessInfo.processInfo.environment["SHELL"].map(CommandRestore.basename)
        var live: [UUID: (pid: pid_t, kind: AgentKind?)] = [:]

        for session in library.allOpenSessions() {
            // the FOCUSED pane, the same one `displayName`/`title` track — a split session shows the agent of
            // the pane you're looking at.
            // ponytail: panes only. An overlay/scratch, and an agent behind tmux/ssh, read as their wrapper.
            guard let view = session.activeSurface as? GhosttySurfaceView, let pid = view.foregroundPid() else {
                if session.agentKind != nil { session.agentKind = nil }
                continue
            }

            let kind: AgentKind?
            if let cached = cache[session.id], cached.pid == pid {
                kind = cached.kind // same process as last tick: its argv cannot have changed, so skip the sysctl
            } else {
                kind = AgentKind.classify(argv: ForegroundProcess.command(for: view, shellBasename: shellBasename))
            }

            live[session.id] = (pid, kind)
            if session.agentKind != kind { session.agentKind = kind }
        }

        cache = live
    }
}
