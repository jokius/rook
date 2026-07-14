import Foundation

/// The agent conversation a pane was running: which agent, which conversation id, and the config
/// directory that conversation lives in. Reported by the agent's own `SessionStart` hook over the
/// control channel (`session.agent`) and persisted per pane, so a restart can RESUME that conversation
/// instead of starting a blank one — the foreground argv alone is just `claude`, which carries no id.
///
/// `configDir` is the agent's config root as it was at launch (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`), nil
/// when the agent ran on its default. It is load-bearing, not decoration: a user who keeps separate
/// work/personal Claude profiles stores each conversation under a DIFFERENT root, and resuming with the
/// wrong one simply fails to find the conversation.
public struct AgentSessionRef: Codable, Equatable, Sendable {
    public let kind: AgentKind
    public let id: String
    public let configDir: String?

    public init(kind: AgentKind, id: String, configDir: String? = nil) {
        self.kind = kind
        self.id = id
        self.configDir = configDir
    }
}

/// Pure, host-free rendering of the command line that RESUMES a pane's agent conversation on restore.
/// The app target only decides when to ask (the `resumeAgentSessions` opt-in, in the same surface
/// factory that already replays `foregroundCommand`); every judgement about what to type lives here.
public enum AgentResume {
    /// The environment variable that points each agent at its config root — the same variable the user's
    /// shell wrapper/alias sets to pick a work vs personal profile.
    public static func configVar(for kind: AgentKind) -> String {
        switch kind {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        }
    }

    /// The arguments that resume conversation `id`, or — with no id — the agent's "continue the last
    /// conversation in this directory" form, which is the honest fallback when no hook ever reported an id.
    static func resumeArgs(for kind: AgentKind, id: String?) -> [String] {
        switch kind {
        case .claude: return id.map { ["--resume", $0] } ?? ["--continue"]
        case .codex: return ["resume", id ?? "--last"]
        }
    }

    /// The captured argv's own flags, minus anything that would fight the resume we are about to add: a
    /// previous `--resume`/`-r`/`--continue`/`-c` (its id argument goes with it), a `--fork-session`
    /// (which would branch a NEW conversation instead of continuing this one), and — for codex — a
    /// leading `resume`/`fork` subcommand with its id. Everything else survives, so a pane started as
    /// `claude --model opus` resumes as `claude --resume <id> --model opus`.
    ///
    /// Only argv whose `argv[0]` IS the agent contributes flags: when the agent ran behind a launcher
    /// (`sh -c 'claude …'`, an `env` prefix), the rest of the argv describes the WRAPPER, not the agent,
    /// so it is dropped rather than guessed at.
    public static func strippedArgs(argv: [String], kind: AgentKind) -> [String] {
        guard let first = argv.first, CommandRestore.basename(first) == kind.rawValue else { return [] }
        var args = Array(argv.dropFirst())

        if kind == .codex, let sub = args.first, sub == "resume" || sub == "fork" {
            args.removeFirst()
            if let next = args.first, next == "--last" || !next.hasPrefix("-") { args.removeFirst() }
        }

        var result: [String] = []
        var i = args.startIndex
        while i < args.endIndex {
            let arg = args[i]
            switch arg {
            case "--fork-session", "--continue", "-c":
                i += 1
            case "--resume", "-r":
                i += 1
                // the id is optional (a bare `--resume` opens the picker), so only swallow a non-flag next arg
                if i < args.endIndex, !args[i].hasPrefix("-") { i += 1 }
            default:
                result.append(arg)
                i += 1
            }
        }
        return result
    }

    /// The command line to type into a restored pane's login shell so it comes back on the SAME
    /// conversation, or nil when `argv` is not this agent (the pane moved on to something else, so the
    /// ordinary foreground re-run applies).
    ///
    /// Rendered as `env VAR='<configDir>' claude --resume <id> …` rather than a bare `claude …` on
    /// purpose: `env` execs the binary from PATH, so it bypasses any shell function or alias wrapping the
    /// agent's name. Users commonly wrap `claude` in a function that re-picks the profile from the
    /// current directory — which would silently resume against the wrong config root (and find no
    /// conversation) for an agent that was launched with an explicit profile.
    public static func resumeLine(argv: [String], ref: AgentSessionRef?) -> String? {
        guard let kind = AgentKind.classify(argv: argv) else { return nil }
        // a ref for a DIFFERENT agent describes a conversation this pane is no longer running
        let id = (ref?.kind == kind) ? ref?.id : nil
        let configDir = (ref?.kind == kind) ? ref?.configDir : nil

        var words: [String] = []
        if let configDir, !configDir.isEmpty {
            words += ["env", "\(configVar(for: kind))=\(CommandRestore.shellQuote(configDir))"]
        }
        words.append(kind.rawValue)
        words += resumeArgs(for: kind, id: id?.isEmpty == false ? id : nil).map(CommandRestore.shellQuote)
        words += strippedArgs(argv: argv, kind: kind).map(CommandRestore.shellQuote)
        return words.joined(separator: " ")
    }
}
