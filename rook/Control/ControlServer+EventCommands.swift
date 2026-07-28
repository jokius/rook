import rookCore

// MARK: - events.read

extension ControlServer {
    /// The one host side effect `events.read` needs: reach the app-wide ring. The ring is owned by
    /// `WindowLibrary` (one per app run, shared by every window store), so there is no target to resolve —
    /// the dispatcher has already validated the cursor, the kind filter, and the limit.
    func readEvents(_ options: ControlEventReadOptions) -> ControlResponse {
        library.readEvents(options)
    }
}
