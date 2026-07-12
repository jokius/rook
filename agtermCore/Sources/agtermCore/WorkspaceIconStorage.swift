import Foundation

/// Host-free on-disk location of workspace icon images — a `workspace-icons/` subdir of the state
/// directory (honoring `AGTERM_STATE_DIR` for test isolation, like the snapshot and the watermark PNGs).
/// Pure Foundation, so the copy lives here rather than app-side; only turning the file into an `NSImage`
/// needs AppKit.
///
/// A user-picked icon is COPIED in rather than referenced in place, so the icon does not vanish when the
/// original is moved or deleted.
///
/// Each function takes an optional `stateDir` override (default nil = the `AGTERM_STATE_DIR`/app-support
/// resolution) so tests can inject a temp directory without mutating process-global env (parallel-safe).
public enum WorkspaceIconStorage {
    /// `<stateDir>/workspace-icons` — NOT created. Use `ensureDirectory()` before writing.
    public static func directoryURL(stateDir: URL? = nil) -> URL {
        let base = stateDir
            ?? ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? PersistenceStore.defaultDirectory
        return base.appendingPathComponent("workspace-icons", isDirectory: true)
    }

    /// `directoryURL()`, created lazily (best effort). Called before copying an icon in.
    @discardableResult
    public static func ensureDirectory(stateDir: URL? = nil) -> URL {
        let dir = directoryURL(stateDir: stateDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies `source` into the icons dir and returns the `.image` spec pointing at the COPY.
    ///
    /// Two subtleties, both load-bearing:
    ///
    /// 1. **Idempotent.** When `source` already lives in the icons dir the file IS the icon — return it
    ///    unchanged and copy nothing. The `tree` read-back hands a script the copy's path, and feeding
    ///    that same path back to `workspace.icon` is the documented record-then-restore flow; without this
    ///    guard, source == destination and the remove-then-copy would delete the only copy.
    /// 2. **A fresh destination name every time** (`<workspaceID>-<8 hex>.<ext>`, not `<workspaceID>.<ext>`).
    ///    A name derived from the workspace id alone makes swapping one file for another produce an
    ///    IDENTICAL `WorkspaceIcon`, which the store's delta guard, the sidebar's `RowContent` diff, and the
    ///    image memo would each swallow — the command would report success and show the old picture until
    ///    the next launch. A new name makes the spec genuinely change, so all three unblock themselves.
    public static func install(source: URL, workspaceID: UUID, stateDir: URL? = nil) throws -> WorkspaceIcon {
        let dir = directoryURL(stateDir: stateDir)
        let sourceDir = source.standardizedFileURL.deletingLastPathComponent()
        if sourceDir == dir.standardizedFileURL {
            return WorkspaceIcon(kind: .image, value: source.standardizedFileURL.path) // already ours
        }
        ensureDirectory(stateDir: stateDir)
        let ext = source.pathExtension.lowercased()
        let name = "\(workspaceID.uuidString)-\(UUID().uuidString.prefix(8)).\(ext)"
        let destination = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        return WorkspaceIcon(kind: .image, value: destination.path)
    }
}
