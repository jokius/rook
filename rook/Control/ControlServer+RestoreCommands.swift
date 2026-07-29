import Foundation
import rookCore

/// `ControlServer`'s `session.restore` arm: the per-session, per-pane restore-command override — the shell
/// line a pane re-runs on the NEXT launch instead of whatever the quit-time capture happened to see. Split
/// out of `ControlServer+SessionActions.swift`, which is already at the file-size limit.
///
/// Not to be confused with the app-global `restore.clear` (`ControlServer.clearRestoreCommands`), which
/// wipes every session's CAPTURED foreground command; this one is per-session and writes an override that
/// wins over that capture.
extension ControlServer {
    /// Pin (or unpin) the target pane's restore-command override. The write takes effect on the NEXT launch
    /// only — `AppStore.setRestoreCommand` touches the persisted field, never the transient pending slot the
    /// surface factories consume — and persists immediately, so a hook's write survives a force quit.
    ///
    /// **Pane resolution diverges from `session.status` on purpose.** A `--pane-id` that resolves against
    /// the session's LIVE surfaces overrides the stale role `--pane`, exactly as there; an EMPTY token
    /// counts as absent (an older shell exporting no `ROOK_PANE_ID`) and takes the plain `--pane`/main-pane
    /// path. But an UNRESOLVABLE non-empty token with no explicit `--pane` is an ERROR rather than a silent
    /// main-pane default: a status lands on the wrong row for a moment, a pin persists and executes.
    /// `.scratch` (never restored) and a `.right` with no split are rejected too.
    ///
    /// A `set` while "Restore running commands on restart" is off still SUCCEEDS — the pin is durable state
    /// and the toggle is the master switch read at launch — but says so in `result.text`, since otherwise
    /// nothing would ever fire and the caller has no other way to notice.
    func setSessionRestore(_ target: String?, window: String?,
                           update: ControlSessionRestoreUpdate) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            let pane: StatusPane
            if let token = update.paneID, !token.isEmpty {
                guard let resolved = session.paneRole(forToken: token) ?? update.pane else {
                    return ControlResponse(ok: false, error: "unknown pane id: \(token)")
                }
                pane = resolved
            } else {
                pane = update.pane ?? .left
            }
            guard pane != .scratch else {
                return ControlResponse(ok: false, error: "the scratch terminal is never restored")
            }
            guard pane != .right || session.hasSplit else {
                return ControlResponse(ok: false, error: "session has no split")
            }
            let value: String?
            switch update.pin {
            case .pin(let command): value = command
            case .pinNone: value = ""
            case .unpin: value = nil
            }
            guard store.setRestoreCommand(value, pane: pane, forSession: id) else {
                return ControlResponse(ok: false,
                                       error: "failed to save the restore override, the previous value is still in effect")
            }
            var result = ControlResult(id: id.uuidString)
            if case .pin = update.pin, self.settingsModel.settings.restoreRunningCommand != true {
                result.text = "saved, but \"Restore running commands on restart\" is off, so the override will not run"
            }
            return ControlResponse(ok: true, result: result)
        }
    }
}
