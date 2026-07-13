import Foundation

// MARK: - Markdown preview panel

extension AppStore {
    /// The preview panel width default and drag/restore bounds, shared by the view's divider drag and the
    /// `restore()` clamp so the two can't drift (and a hand-edited snapshot can't drive an out-of-range frame).
    /// Wider than the file tree's: this one holds prose, not filenames.
    public static let markdownWidthDefault: Double = 420
    public static let markdownWidthMin: Double = 260
    public static let markdownWidthMax: Double = 900

    /// Opens (or re-targets) a session's Markdown preview panel on `path` and persists it. The refresh token
    /// is bumped even when the path is UNCHANGED, so clicking the same link twice re-reads the file instead of
    /// showing a stale render — the common case with an agent that keeps rewriting the plan it just linked.
    /// `path` is expected absolute and already validated (`LinkPolicy` / the control arm); this only records
    /// it. No-op for an unknown id.
    public func openMarkdown(_ path: String, forSession id: UUID) {
        guard let session = session(withID: id) else { return }
        session.markdownRefreshToken &+= 1
        guard session.markdownPath != path else { return }   // same file: the token bump above is the whole job
        session.markdownPath = path
        save()
    }

    /// Closes a session's preview panel. Clean no-op (no write) when it is already closed, so the
    /// delta-computed menu/control callers stay idempotent.
    public func closeMarkdown(_ id: UUID) {
        guard let session = session(withID: id), session.markdownPath != nil else { return }
        session.markdownPath = nil
        save()
    }

    /// Flips the preview panel: open on `path` when closed (or showing a DIFFERENT file), close when it is
    /// already showing this one. `path` nil means "close if open, otherwise nothing to show" — the menu/keybind
    /// form, which has no file of its own to offer. No-op for an unknown id.
    public func toggleMarkdown(_ id: UUID, path: String? = nil) {
        guard let session = session(withID: id) else { return }
        guard let path, session.markdownPath != path else { return closeMarkdown(id) }
        openMarkdown(path, forSession: id)
    }
}
