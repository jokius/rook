import Foundation

extension AppStore {
    /// Remembers (or forgets, with a nil `ref`) the agent conversation a pane is on — the single mutation
    /// point for the control channel's `session.agent`. No-op for an unknown id.
    ///
    /// Unlike the ephemeral agent INDICATOR, this is persisted (a restart is the whole point), so a change
    /// saves; an unchanged value is a clean no-op and does not.
    ///
    /// A `.right` pane is normalized to the main pane when the session has NO split, for the same reason
    /// `setAgentIndicator` does it: a promoted split survivor keeps its baked `ROOK_PANE=right`, so its
    /// agent's hook keeps reporting `--pane right` for what is now the main pane.
    public func setAgentSession(_ ref: AgentSessionRef?, forSession id: UUID, pane: StatusPane?) {
        guard let session = session(withID: id) else { return }
        let toSplit = (pane == .right) && session.hasSplit
        if toSplit {
            guard session.splitAgentSession != ref else { return }
            session.splitAgentSession = ref
        } else {
            guard session.agentSession != ref else { return }
            session.agentSession = ref
        }
        save()
    }
}
