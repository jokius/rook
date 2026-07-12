import Foundation

/// One-shot import of a pre-rebrand **agterm** install into rook's paths, run at launch before anything
/// reads either directory.
///
/// rook reads `~/Library/Application Support/rook` and `~/.config/rook`; an install upgraded from agterm
/// has its whole world (windows/workspaces, settings, keymap, ghostty config) under the `agterm`-named
/// siblings, so without this a rebranded build opens on an empty tree.
///
/// The copy is COPY, never move — the legacy directories stay untouched as a backup — and it is latched by
/// the destination's existence: a destination that already exists (a previous migration, or a genuinely
/// fresh rook install that already wrote a file) is left alone, so this is idempotent and can't clobber
/// live state. File CONTENTS are never rewritten: a `keymap.conf` custom command is the user's own shell
/// code, not ours to edit.
public enum LegacyMigration {
    /// The pre-rebrand directory name, under both `~/Library/Application Support` and `~/.config`.
    public static let legacyName = "agterm"

    /// The rook directory name, the migration destination under the same two parents.
    public static let name = "rook"

    /// What the migration copied, per directory (names only; empty = nothing was done).
    public struct Result: Equatable, Sendable {
        public var state: [String]
        public var config: [String]

        public init(state: [String] = [], config: [String] = []) {
            self.state = state
            self.config = config
        }

        public var isEmpty: Bool { state.isEmpty && config.isEmpty }
    }

    /// Skipped in the state dir: the control socket. It is a runtime rendezvous re-bound on every launch,
    /// not state — copying it would only leave a dead inode for `ControlServer.start()` to unlink.
    static func skipInState(_ name: String) -> Bool { name.hasSuffix(".sock") }

    /// Skipped in the config dir: `agent-status/`. It is an install OUTPUT — `AgentHooksInstaller` copies
    /// the scripts out of the app bundle and BAKES the installing app's absolute `rookctl` path into them —
    /// so a copied agterm-era hook set would keep driving the OLD binary. Help ▸ Install Agent Status Hooks…
    /// regenerates it (and rewrites the shell-rc block) against the new app.
    static func skipInConfig(_ name: String) -> Bool { name == "agent-status" }

    /// Migrate both directories: `<appSupport>/agterm` → `<appSupport>/rook` and `<home>/.config/agterm` →
    /// `<home>/.config/rook`.
    ///
    /// A set `stateDir` (the `ROOK_STATE_DIR` value) means a deliberately isolated dev/test instance, which
    /// must never inherit the real install's state — so migration is skipped entirely.
    @discardableResult
    public static func run(home: URL, appSupport: URL, stateDir: String?,
                           fileManager: FileManager = .default) -> Result {
        if let stateDir, !stateDir.isEmpty { return Result() }
        let config = home.appendingPathComponent(".config", isDirectory: true)
        return Result(
            state: copyDirectory(from: appSupport.appendingPathComponent(legacyName, isDirectory: true),
                                 to: appSupport.appendingPathComponent(name, isDirectory: true),
                                 skipping: skipInState, fileManager: fileManager),
            config: copyDirectory(from: config.appendingPathComponent(legacyName, isDirectory: true),
                                  to: config.appendingPathComponent(name, isDirectory: true),
                                  skipping: skipInConfig, fileManager: fileManager)
        )
    }

    /// Copy every child of `source` into a freshly created `destination`, skipping the named entries.
    /// No-op (empty result) when `destination` already exists, `source` is missing, or nothing survives the
    /// skip filter — the destination is only created when there is something to put in it. Returns the
    /// names actually copied; an individual failing item is dropped rather than failing the whole run.
    static func copyDirectory(from source: URL, to destination: URL, skipping skip: (String) -> Bool,
                              fileManager: FileManager) -> [String] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue,
              !fileManager.fileExists(atPath: destination.path),
              let names = try? fileManager.contentsOfDirectory(atPath: source.path) else { return [] }
        let wanted = names.filter { !skip($0) }.sorted()
        guard !wanted.isEmpty,
              (try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)) != nil
        else { return [] }
        return wanted.filter { name in
            (try? fileManager.copyItem(at: source.appendingPathComponent(name),
                                       to: destination.appendingPathComponent(name))) != nil
        }
    }
}
