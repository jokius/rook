import Foundation

/// AgentKind is the coding agent a session's focused pane currently runs, classified from that pane's
/// foreground-process argv (libghostty's `ghostty_surface_foreground_pid` → `sysctl(KERN_PROCARGS2)`,
/// both app-side; see `ForegroundProcess` and `AgentMonitor`). It drives the sidebar row icon — a Claude
/// or OpenAI logo instead of the terminal glyph — and rides the control tree as a read-only field.
///
/// Distinct from `AgentStatus`, which is the agent's SELF-REPORTED turn state pushed over the control
/// channel by its hooks (`session.status`). This one is OBSERVED from the process table: it needs no
/// hooks, no shell integration, and it is true for any agent — including one nobody wired up.
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude, codex

    /// Launchers that exec the real agent, so `argv[0]` names the wrapper, not the agent: a `#!/bin/sh`
    /// shim, an `npx`/`bun` runner, an `env` prefix. `CommandRestore.isIdleShell` already lets such an argv
    /// through (a shell RUNNING something is a real foreground process), so the classifier looks one
    /// argument further for them — the same wrapper case the restore capture was extended to handle.
    private static let launchers: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "env", "node", "bun", "deno", "npx", "pnpm", "yarn",
    ]

    /// The agent running as `argv`, or nil when it is anything else (a plain command, a shell at its
    /// prompt — `ForegroundProcess.command` already returns nil for that).
    ///
    /// Matches the argv[0] BASENAME exactly (`/opt/homebrew/bin/claude` → `claude`), never a prefix — a
    /// hypothetical `claude-monet` is not Claude Code. When argv[0] is a launcher, the first non-flag
    /// argument's basename is classified instead (`/bin/sh /usr/local/bin/cld` → `cld`, no match; `node
    /// …/claude.js` → `claude.js`, no match — a wrapper only resolves when it execs the agent under its
    /// own name, which is the common `#!/bin/sh` + `exec claude` shim).
    public static func classify(argv: [String]?) -> AgentKind? {
        guard let argv, let first = argv.first else { return nil }
        var name = CommandRestore.basename(first)
        if launchers.contains(name), let next = argv.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            name = CommandRestore.basename(next)
        }
        return AgentKind(rawValue: name)
    }
}
