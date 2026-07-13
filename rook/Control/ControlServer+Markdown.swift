import Foundation
import rookCore

/// `ControlServer` Markdown-preview arm — the `session.markdown` command's app-side side effects
/// (open/close/toggle the right-hand preview panel), including the path resolution + existence check the
/// host-free dispatcher can't do. Mirrors `ControlServer+FileTree.swift`.
extension ControlServer {
    func markdownSession(_ target: String?, window: String?, mode: ControlToggleMode,
                         path: String?) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            // no path: `close`, or the bare `toggle` (= close an open panel — there's nothing to show).
            guard let path, mode != .off else {
                if mode == .off { store.closeMarkdown(id) } else { store.toggleMarkdown(id) }
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
            // FS validation is app-side (the dispatcher stays host-free): the file must exist and not be a
            // directory. The EXTENSION is deliberately unchecked — a script may preview any text file; the
            // panel just renders it as Markdown. Mirrors the `session.filetree reroot` directory check.
            let resolved = Self.resolveMarkdownPath(path, cwd: session.effectiveCwd)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), !isDir.boolValue else {
                return ControlResponse(ok: false, error: "no such file: \(resolved)")
            }
            // `openMarkdown` bumps the refresh token even for the same path, so re-opening a file an agent
            // just rewrote re-reads it instead of showing a stale render.
            if mode == .on {
                store.openMarkdown(resolved, forSession: id)
            } else {
                store.toggleMarkdown(id, path: resolved)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// `~` expands; a relative path resolves against the session's cwd (so `rookctl session markdown open PLAN.md`
    /// works from a shell sitting in the project). An absolute path ignores the base, per `URL(fileURLWithPath:relativeTo:)`.
    static func resolveMarkdownPath(_ path: String, cwd: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true))
            .standardizedFileURL.path
    }
}
