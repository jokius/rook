import Foundation
import rookCore

/// The app-side half of `--shell` validation, shared by the three commands that accept one
/// (`session.new`, `window.new`, `quick`). The dispatcher owns the host-free half — that the path is
/// absolute and control-character free (`SurfaceCommand.isValidShellPath`) — and this owns the leg that
/// needs a filesystem: that the path EXISTS and is EXECUTABLE. Same split as `session.background`, which
/// checks the image's format host-free and its existence here.
extension ControlServer {
    /// nil when the shell is absent or usable; the rejection to answer with otherwise. Like every other
    /// up-front control validation, a failure returns BEFORE anything is created, so the state is unchanged.
    func rejectUnusableShell(_ shell: String?) -> ControlResponse? {
        guard let shell else { return nil }
        // a directory carries the same execute bit (it means "searchable"), so `isExecutableFile` alone
        // would wave `--shell /usr/bin` through and hand the caller a session that dies at spawn.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: shell, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: shell) else {
            return ControlResponse(ok: false, error: "shell not found or not executable: \(shell)")
        }
        return nil
    }
}
