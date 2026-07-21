import rookCore
import Foundation

/// `AppActions` policy helpers for creating and closing sessions — where a new session opens (workspace
/// root / the global new-session-directory setting) and the close-confirmation copy + undo-grace duration.
/// Split out of `AppActions.swift` to keep that hub file under the swiftlint size limit, like the other
/// `AppActions+*` extensions.
extension AppActions {
    /// The working directory a new session should open in. A workspace `root` (when set AND still an
    /// existing directory) HARD-overrides everything; otherwise the global new-session-directory setting
    /// applies (home / the current session's cwd / a fixed custom dir), resolved against the active
    /// session's focused-pane cwd. Shared by `newSession()` and the sidebar's workspace-row New Session so
    /// both honor the setting. Falls back to home when `settingsModel` isn't wired yet (before the scene
    /// `.task`). Read as the `addSession` argument, so it captures the active session's cwd BEFORE the new
    /// session exists.
    func resolvedNewSessionCwd(inWorkspace workspaceID: UUID? = nil) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // a workspace root, when set AND still an existing directory, hard-overrides the global
        // new-session-directory setting (see AppSettings.resolveNewSessionCwd); a stale/removed root falls
        // back to the global logic, so a new session never spawns into a missing directory.
        let rootSetting = workspaceID.flatMap { id in store?.workspaces.first { $0.id == id }?.root }
        let root = Self.existingDirectory(rootSetting)
        return settingsModel?.settings.resolveNewSessionCwd(
            workspaceRoot: root, currentSessionCwd: store?.activeSession?.focusedCwd, home: home) ?? home
    }

    /// `path` when it names an existing directory, else nil — the app-side filesystem check the host-free
    /// `resolveNewSessionCwd` deliberately can't do. Used to reject a workspace root that was moved or
    /// deleted so new sessions fall back to the global setting instead of failing to spawn. Also consulted
    /// by `ControlServer.makeSessionResponse` for the control `session.new` path.
    static func existingDirectory(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return path
    }

    /// The undo grace window a soft close keeps before final teardown, from Settings ▸ Interface ▸ Undo
    /// (`AppSettings.closeGraceSeconds`, default 5s). Threaded into every soft-close so the toast countdown
    /// and the undo window share the one duration.
    var effectiveCloseGraceSeconds: TimeInterval {
        settingsModel?.settings.effectiveCloseGraceSeconds ?? 5
    }

    /// The confirm-close alert's informative line: the base "what happens on close" sentence (singular or
    /// plural, reflecting the undo-grace setting), prefixed with a running-agent warning when `agent` is
    /// set so a live coding agent isn't closed unknowingly. Shared by the single (`confirmCloseSession`)
    /// and batch (`confirmCloseSessions`) alerts; the batch passes the first running agent and gets the
    /// "one of these sessions" phrasing from `count`.
    func closeConfirmInformativeText(agent: AgentKind?, count: Int) -> String {
        let subject = count == 1 ? "The session will" : "The sessions will"
        let base = closeGraceUndoEnabled
            ? "\(subject) close after a short undo window."
            : "\(subject) close immediately and can be reopened from File > Open Recent."
        guard let agent else { return base }
        let place = count == 1 ? "this session" : "one of these sessions"
        return "A \(agent.rawValue.capitalized) agent is running in \(place). " + base
    }
}
