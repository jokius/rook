extension GhosttySurfaceView {
    // MARK: - Pane role

    /// `TerminalSurface` conformance: the model calls this when the primary pane exits and this split
    /// (right) pane is promoted to the session's sole pane. Clears `isSplitPane` so subsequent
    /// `applyPwd`/`applyTitle` reports route to `session.currentCwd`/`oscTitle` (the main fields) rather
    /// than `splitCwd`/`splitTitle`.
    func promoteToPrimaryPane() {
        isSplitPane = false
    }

    /// `TerminalSurface.isRealized`: the libghostty surface — and with it the spawned program — EXISTS, as
    /// opposed to this view merely occupying a session slot. False while `createSurface` is still deferred
    /// on a zero backing size (`pendingSurfaceCreation`) and after `destroySurface`, both of which leave
    /// `surface` nil. `Session.dropUnrealizedPaneOverlays` keys on it to tell a stranded pane overlay from
    /// a live one.
    var isRealized: Bool { surface != nil }

    /// `TerminalSurface.paneToken`: this surface's stable spawn identity, read straight back from the baked
    /// `ROOK_PANE_ID` env value the shell also carries (empty for a surface spawned without a pane — the
    /// overlay / quick terminal). Distinct from the LIVE role (`isSplitPane`), which promotion flips; the
    /// token never changes, so `Session.paneRole(forToken:)` maps a status hook's `--pane-id` to the
    /// surface's CURRENT slot even after a promote + re-split.
    var paneToken: String { env["ROOK_PANE_ID"] ?? "" }
}
