import Foundation

/// Host-free core of the quit-time agent drain: who is worth waiting for, and the strings the app
/// target hands to the agent and to the user.
///
/// The predicate is deliberately `AgentStatus.active` and NOT `Session.agentKind != nil` (what
/// `confirmCloseOnlyRunningAgent` uses): `active` is written by the very hook that will read the flag
/// file, so "who we wait for" and "who can hear us" are the same set by construction. A session with
/// no hooks installed never reaches `active`, and waiting for it would buy nothing — it could not
/// observe the warning either way.
public enum ShutdownDrain {
    /// The drain flag's file name, dropped next to the control socket.
    public static let flagFileName = "shutdown"

    /// The flag path for a given control-socket path — the socket's directory plus `flagFileName`.
    ///
    /// The socket path is what the app already exports to every surface as `ROOK_SOCKET`
    /// (`SurfaceEnvironment`), and it is always emitted, so the hook can always derive this. The state
    /// directory is NOT exported, which is why the socket is the anchor.
    public static func flagPath(socketPath: String) -> String {
        let directory = (socketPath as NSString).deletingLastPathComponent
        return (directory as NSString).appendingPathComponent(flagFileName)
    }

    /// How many of the given per-session statuses are mid-turn.
    public static func activeCount(_ statuses: [AgentStatus]) -> Int {
        statuses.count(where: { $0 == .active })
    }

    /// Whether a quit should drain at all: at least one mid-turn agent AND a positive grace budget.
    /// A non-positive budget is the user's off switch, so it short-circuits before anything is written.
    public static func shouldDrain(statuses: [AgentStatus], graceSeconds: TimeInterval) -> Bool {
        graceSeconds > 0 && activeCount(statuses) > 0
    }

    /// The single line written into the flag file — what the agent itself reads.
    ///
    /// One line, no newline: the hook slurps it with a `read` builtin (bash 3.2, no forks on the
    /// per-tool-call hot path), which stops at the first newline and would silently drop the rest.
    public static func flagMessage(seconds: Int) -> String {
        "rook is closing this terminal in about \(seconds)s. Stop what you are doing now: either write a "
            + "short handoff note (what you did, where you stopped, what is next) or wrap up cleanly. "
            + "Do not start anything new."
    }

    /// The sheet line shown while the app waits.
    public static func waitingMessage(activeCount: Int, secondsLeft: Int) -> String {
        let agents = activeCount == 1 ? "1 agent " : "\(activeCount) agents "
        return "Waiting for \(agents)to wrap up — \(secondsLeft)s left."
    }

    /// The extra line appended to the ⌘Q confirmation when a drain will follow, or nil when it will not.
    public static func quitPromptSuffix(activeCount: Int, graceSeconds: TimeInterval) -> String? {
        guard graceSeconds > 0, activeCount > 0 else { return nil }
        let agents = activeCount == 1 ? "1 agent is" : "\(activeCount) agents are"
        let seconds = Int(graceSeconds.rounded())
        return "\(agents) still working — rook will ask them to wrap up and wait up to \(seconds)s."
    }
}
