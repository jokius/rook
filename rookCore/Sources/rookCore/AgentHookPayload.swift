import Foundation

/// The slice of an agent hook's stdin JSON that rook cares about. Claude Code and Codex both hand their
/// hooks a JSON object on stdin carrying `session_id` (the conversation id) — the ONE thing that is
/// nowhere in the process table, so it can only come from the agent itself.
///
/// Parsing lives here rather than in the installed hook script so the script stays a thin no-op-safe
/// wrapper with no `jq` dependency: the script pipes stdin straight into `rookctl session agent`, which
/// decodes it with this type.
public struct AgentHookPayload: Decodable, Equatable, Sendable {
    public let sessionID: String
    public let cwd: String?
    /// Claude's `SessionStart` source (`startup`/`resume`/`clear`/`compact`); absent on other events and
    /// on Codex.
    public let source: String?
    /// The absolute path of the conversation's transcript file — the file `claude --resume` resolves a
    /// conversation by. Present in Claude's hook payload; absent on older agents.
    public let transcriptPath: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd, source
        case transcriptPath = "transcript_path"
    }

    /// Decode a hook payload, or nil when the input is not JSON, is not an object, or carries no
    /// (non-empty) `session_id`. Never throws: a hook that cannot report an id must degrade to a silent
    /// no-op, never to a failing hook that blocks the agent's turn.
    public static func parse(_ data: Data) -> AgentHookPayload? {
        guard let payload = try? JSONDecoder().decode(AgentHookPayload.self, from: data),
              !payload.sessionID.isEmpty else { return nil }
        return payload
    }

    /// The id to RESUME this conversation by, which is NOT always the live `session_id` the hook reports.
    ///
    /// `claude --resume <id>` resolves a conversation by its TRANSCRIPT FILE stem, and for a RESUMED or
    /// forked conversation that stem DIVERGES from `session_id`: Claude keeps appending to the ORIGINAL
    /// file (`<root>.jsonl`) while stamping each new turn with a fresh `session_id`, so no `<session_id>.jsonl`
    /// file ever exists and resuming by `session_id` silently finds nothing. So for claude, prefer the file
    /// stem of `transcript_path`, falling back to `session_id` only when no usable path is present.
    ///
    /// Codex is the opposite: `codex resume <id>` resolves by the session id, not by the rollout file name,
    /// so its resume id is always the reported `session_id`.
    public func resumeID(for kind: AgentKind) -> String {
        switch kind {
        case .claude:
            if let transcriptPath, let file = transcriptPath.split(separator: "/").last {
                let stem = file.hasSuffix(".jsonl") ? file.dropLast(".jsonl".count) : file
                if !stem.isEmpty { return String(stem) }
            }
            return sessionID
        case .codex:
            return sessionID
        }
    }
}
