import Foundation

/// The one-time pointer at the optional extras under the Help menu, shown on a first launch only. Owns the
/// due-decision, its marker, and the copy; the AppKit alert and the installers it runs live app-side.
public enum FirstRunWelcome {
    /// Files a previous launch leaves behind. The control socket is excluded: it is bound before the scene
    /// task runs, so its presence says nothing about earlier launches.
    static let priorStateNames = ["settings.json", "workspaces.json", "windows"]

    /// The marker the showing launch drops next to the snapshot. It lives in the state directory rather
    /// than in `AppSettings` so it is scoped by the same `ROOK_STATE_DIR` that scopes everything else —
    /// an isolated dev/test instance decides for itself — and so settings stay user-facing preferences.
    static let markerName = "welcome-shown"

    public static let title = "Welcome to Rook"

    public static let message = """
    Rook ships optional extras. These two install from here, and all of them from the Help menu at any time:

    The agent skill teaches Claude Code and Codex to drive Rook over its control socket.

    The agent status hooks make an agent session report active, blocked or completed in the sidebar.

    The command line tool puts rookctl on your PATH. A Homebrew install already has it, so that one is \
    only for a direct download.
    """

    public static let skillOption = "Install the agent skill"

    public static let hooksOption = "Install the agent status hooks"

    /// Whether any prior-launch state exists in `directory`. Must be read before the app writes anything,
    /// since the first launch seeds a session and saves its window within a second of the scene appearing.
    public static func hasPriorState(in directory: URL) -> Bool {
        priorStateNames.contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// Whether to show the welcome: never twice, and never to a user who has run Rook before. The two terms
    /// answer different questions, so both are needed. The marker covers a state directory that carries it,
    /// and `hasPriorState` covers everyone who upgraded into this feature, whose state predates the marker
    /// and would otherwise read as a fresh install.
    public static func isDue(in directory: URL) -> Bool {
        !FileManager.default.fileExists(atPath: marker(in: directory).path) && !hasPriorState(in: directory)
    }

    /// Drop the marker, so no later launch on this state directory shows the welcome again. Best-effort:
    /// an unwritable state directory means the app has bigger problems than a repeated welcome.
    public static func markShown(in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker(in: directory).path, contents: nil)
    }

    static func marker(in directory: URL) -> URL { directory.appendingPathComponent(markerName) }
}
