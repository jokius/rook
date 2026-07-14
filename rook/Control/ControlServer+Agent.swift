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

}
