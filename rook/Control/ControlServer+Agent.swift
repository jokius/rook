import AppKit
import Foundation
import rookCore

/// `ControlServer`'s `session.agent` arm: remembering which agent CONVERSATION a pane is on, so a restart
/// can resume it rather than open a blank one. Split out of `ControlServer+SessionActions.swift`, which is
/// already at the file-size limit.
extension ControlServer {
    /// Remember which agent conversation the target pane is on (`session.agent`), so a restart can resume
    /// it instead of opening a blank one. The caller is the agent's own hook — the only party that knows
    /// the id.
    ///
    /// **Ownership check.** A hook cannot prove which agent fired it from its environment: an agent
    /// rewrites `CLAUDE_CODE_SESSION_ID` (and every other marker) for its children, so a NESTED `claude -p`
    /// the pane's own agent spawned inherits the same `ROOK_SESSION_ID`/`ROOK_PANE` and looks identical —
    /// it would happily overwrite the pane's conversation with its own throwaway one. What does
    /// distinguish them is the process tree: `rookctl` reports its nearest agent ANCESTOR
    /// (`AgentProcess.nearestAgentPid`), and only the pane's own agent is that pane's FOREGROUND process.
    /// So a mismatch is dropped — reported as ok (a hook must never fail the agent's turn), but nothing is
    /// written. A nil `agentPid` (a human calling `rookctl` by hand) skips the check.
    func setAgentSession(_ target: String?, window: String?, update: ControlAgentSessionUpdate) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
            if let claimed = update.agentPid {
                let pane = (update.pane == .right && session.hasSplit) ? session.splitSurface : session.surface
                guard let view = pane as? GhosttySurfaceView,
                      let foreground = view.foregroundPid(), Int(foreground) == claimed else {
                    return ControlResponse(ok: true, result: ControlResult(id: id.uuidString,
                                                                           text: "ignored: not the pane's agent"))
                }
            }
            store.setAgentSession(update.ref, forSession: id, pane: update.pane)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// The `session.status` half of the same ownership check: does `claimed` PROVABLY belong to someone
    /// other than the pane's own agent? A nested `claude -p` inherits the pane's `ROOK_SESSION_ID`, so
    /// without this it moves the sidebar row — reporting `completed` while the pane's real agent is still
    /// working.
    ///
    /// Unlike `setAgentSession` above this is fail-OPEN — it drops ONLY what it can PROVE is foreign, and
    /// everything unprovable passes. `session.agent` writes persistent state (which conversation to
    /// resume), where losing a write beats storing a stranger's; a status is an ephemeral signal, and
    /// losing a `blocked` — the agent waits for a human while the row says nothing — is worse than one
    /// stray `active`. So a drop needs THREE things to line up:
    ///
    /// 1. a `claimed` pid at all. The CLI reports one only when the call names its OWN session, so a
    ///    cross-session status (an orchestrator flagging another pane) arrives unclaimed and is never
    ///    weighed against a pane it was never running in.
    /// 2. an AGENT at the head of the pane. Behind tmux, ssh, or a bare shell the foreground process is
    ///    the wrapper, never the agent, so its pid could not match even for the pane's rightful agent —
    ///    judging ownership there would break every tmux user's status reporting, which works today.
    /// 3. the pids actually differ.
    ///
    /// It does NOT catch IN-PROCESS subagents (Task, teammates, Workflow): their hooks run in the pane's
    /// own `claude`, so the pid matches — and that is now DELIBERATE. Their reports are the only sign of
    /// life a swarming session has (the lead sits idle waiting for them), so `rook-agent-status.sh` lets
    /// them through; what it does instead is refuse to report `completed` while the payload's
    /// `background_tasks` still lists live work. An earlier version filtered them out by `agent_type` and
    /// that is gone — do not resurrect it here.
    func isForeignAgent(_ claimed: Int?, session: Session?, pane: StatusPane?) -> Bool {
        guard let claimed, let session else { return false }
        let surface: (any TerminalSurface)?
        switch pane {
        case .right where session.hasSplit: surface = session.splitSurface
        case .scratch: surface = session.scratchSurface
        default: surface = session.surface
        }
        guard let view = surface as? GhosttySurfaceView, let foreground = view.foregroundPid() else {
            return false
        }
        // `command`, NOT the descending `running` — and this is a DELIBERATE divergence from `AgentMonitor`,
        // which reads the same pane with `running` for the sidebar logo. The two answer different questions:
        // the logo only has to NAME the program, while this gate compares the classified process against a
        // pid. `foregroundPid()` is a process GROUP id, so for the very panes the descent would newly
        // classify — a `--command` pane, whose program sits in setuid-root `login`'s group — it is LOGIN's
        // pid, while the hook's `claimed` (`AgentProcess.nearestAgentPid`) is the agent's own. They can never
        // be equal, so descending here would satisfy condition 2 and then fail condition 3 for the pane's
        // OWN rightful agent: every status it reports would be silently dropped as foreign. That flips the
        // documented fail-OPEN default (an unprovable head PASSES) into a fail-CLOSED drop on the one pane
        // shape that cannot defend itself. Making the comparison descend too is a design change with its own
        // trade-offs, not a defect fix — see the `session.status --agentPid` note in
        // `.claude/rules/control-api.md`.
        let shellBasename = ProcessInfo.processInfo.environment["SHELL"].map(CommandRestore.basename)
        let argv = ForegroundProcess.command(for: view, shellBasename: shellBasename)
        guard AgentKind.classify(argv: argv) != nil else { return false }
        return Int(foreground) != claimed
    }
}
