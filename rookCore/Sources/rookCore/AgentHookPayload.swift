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

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd, source
    }

    /// Decode a hook payload, or nil when the input is not JSON, is not an object, or carries no
    /// (non-empty) `session_id`. Never throws: a hook that cannot report an id must degrade to a silent
    /// no-op, never to a failing hook that blocks the agent's turn.
    public static func parse(_ data: Data) -> AgentHookPayload? {
        guard let payload = try? JSONDecoder().decode(AgentHookPayload.self, from: data),
              !payload.sessionID.isEmpty else { return nil }
        return payload
    }
}
