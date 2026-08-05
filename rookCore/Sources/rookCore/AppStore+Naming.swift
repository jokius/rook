import Foundation

/// The rename mutators. Both SANITIZE before trimming: a session/workspace name reaches a custom-command
/// token (`{AGT_SESSION_NAME}`/`{AGT_WORKSPACE_NAME}`) that expands UNQUOTED into a `/bin/sh -c` line, so an
/// interior newline is a statement separator there — the same vector `TerminalText.sanitized` already closes
/// on the OSC title/cwd path, which `trimmedOrNil` alone does not (it strips SURROUNDING whitespace only).
/// Sanitizing in the store covers the control arms, the GUI rename, and any future caller at once.
/// Scope is the invisible control-character vector; visible shell metacharacters stay the caller's concern
/// via the shell-quoted `$AGT_X` environment form.
///
/// Split out of `AppStore.swift` to keep that file under the swiftlint size limit.
extension AppStore {
    /// Sets a session's custom name. An empty (or whitespace-only) name clears
    /// `customName` to nil, reverting the row to the auto basename.
    public func renameSession(_ sessionID: UUID, to name: String) {
        guard let session = session(withID: sessionID) else { return }
        let renamed = TerminalText.sanitized(name).trimmedOrNil
        guard session.customName != renamed else { return } // a same-value rename is not a tree change
        session.customName = renamed
        scheduleTreeChanged()
        save()
    }

    /// Renames a workspace. An empty (or whitespace-only) name is ignored —
    /// workspaces have no auto fallback, so a blank name is rejected.
    public func renameWorkspace(_ workspaceID: UUID, to name: String) {
        guard let trimmed = TerminalText.sanitized(name).trimmedOrNil,
              let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              workspaces[index].name != trimmed else { return } // blank and same-value names are no-ops
        workspaces[index].name = trimmed
        scheduleTreeChanged()
        save()
    }
}
