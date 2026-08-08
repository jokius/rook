import Foundation

/// Builds the string handed to libghostty's `config.command` for a spawned surface.
///
/// This is the ONE place that decides what a new shell actually execs. It is host-free on purpose:
/// the app target only supplies the caller's shell (when one was addressed over the control channel)
/// and its own default, and every judgement about quoting and login-shell wrapping lives here.
///
/// Background: on macOS the pinned libghostty routes BOTH command forms through
/// `/usr/bin/login -flp <user>`, so a login TRAMPOLINE is always present. What decides whether the
/// user's rc files run is which program ends up as the login shell — `--command claude` makes
/// `claude` itself the login shell, which naturally reads no rc. Wrapping the command in a real
/// shell (`<shell> -l -c '<cmd>'`) is what restores the user's environment.
public enum SurfaceCommand {
    /// The value for `config.command`, or nil to leave libghostty on its own default shell.
    ///
    /// - `shell` nil, `command` nil: nil — byte-identical to the pre-feature behavior.
    /// - `shell` set, `command` nil: that shell, spawned as the session's login shell.
    /// - `shell` nil, `command` set: the command wrapped in `defaultShell` as a login shell.
    /// - both set: the command wrapped in `shell` as a login shell.
    ///
    /// An empty/whitespace-only `command` counts as absent, and so does a `shell` that fails
    /// `isValidShellPath` — a restored snapshot reaches this without passing the dispatcher, and
    /// degrading to the default shell beats spawning a surface that cannot work.
    public static func resolve(shell: String?, command: String?, defaultShell: String) -> String? {
        let shell = shell.flatMap { isValidShellPath($0) ? $0 : nil }
        guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return shell.map(quotedPath)
        }
        return "\(quotedPath(shell ?? defaultShell)) -l -c \(CLIInstall.shellQuote(command))"
    }

    /// Whether a caller-supplied shell path is well-formed: an absolute path carrying no control
    /// characters. Existence and executability are deliberately NOT checked here — those need the
    /// filesystem and belong to the app target.
    public static func isValidShellPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.rangeOfCharacter(from: .controlCharacters) == nil
    }

    /// Characters a shell path may carry through one round of tokenization untouched; anything else
    /// (a space, a glob, a quote, a non-ASCII scalar) gets the same single-quoting as the command.
    private static let plainPathCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-+")

    private static func quotedPath(_ path: String) -> String {
        path.unicodeScalars.allSatisfy(plainPathCharacters.contains) ? path : CLIInstall.shellQuote(path)
    }
}
