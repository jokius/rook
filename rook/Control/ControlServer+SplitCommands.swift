import Foundation
import rookCore

/// `ControlServer`'s split-teardown arm. Its own file rather than another entry in
/// `ControlServer+SessionActions.swift`, which is already at the swiftlint size limit.
extension ControlServer {
    /// Tear the target's split pane down, which `session.split off` cannot: it hides and keeps the shell.
    /// Kills whatever the pane runs, the point of it — `session.type $'exit\n'` reaches only a shell at a
    /// prompt. Idempotent: no right pane answers ok, so a script need not read `tree` first.
    func closeSessionSplit(_ target: String?, window: String?) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            guard session.hasSplit else {
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
            store.closeSplit(id)
            actions.focusSplitPane(session, wantSplit: false)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }
}
