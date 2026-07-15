import Foundation
import Testing
@testable import rookCore

@Suite("AgentResume")
struct AgentResumeTests {
    @Test("claude resumes its conversation in the profile it ran under")
    func claudeResumesWithConfigDir() {
        let ref = AgentSessionRef(kind: .claude, id: "0f42465a-c037-438f-a08f-5aa29e2e292e",
                                  configDir: "/Users/x/.claude-work")
        let line = AgentResume.resumeLine(argv: ["claude"], ref: ref)
        #expect(line == "env CLAUDE_CONFIG_DIR='/Users/x/.claude-work' claude '--resume' "
                + "'0f42465a-c037-438f-a08f-5aa29e2e292e'")
    }

    @Test("codex resumes through its own subcommand and config root")
    func codexResumes() {
        let ref = AgentSessionRef(kind: .codex, id: "019f5c97-8c56-78e1", configDir: "/Users/x/.codex")
        let line = AgentResume.resumeLine(argv: ["codex"], ref: ref)
        #expect(line == "env CODEX_HOME='/Users/x/.codex' codex 'resume' '019f5c97-8c56-78e1'")
    }

    @Test("no config root means no env prefix")
    func noConfigDirNoPrefix() {
        let line = AgentResume.resumeLine(argv: ["claude"], ref: AgentSessionRef(kind: .claude, id: "abc"))
        #expect(line == "claude '--resume' 'abc'")
    }

    /// The honest fallback when no hook ever reported an id: continue the directory's last conversation.
    @Test("no remembered conversation falls back to --continue")
    func noRefFallsBackToContinue() {
        #expect(AgentResume.resumeLine(argv: ["claude"], ref: nil) == "claude '--continue'")
        #expect(AgentResume.resumeLine(argv: ["codex"], ref: nil) == "codex 'resume' '--last'")
    }

    /// A ref left over from a pane that has since moved on to a DIFFERENT agent must not be used.
    @Test("a ref for another agent is ignored, and its config root with it")
    func mismatchedRefIsIgnored() {
        let ref = AgentSessionRef(kind: .codex, id: "codex-id", configDir: "/Users/x/.codex")
        let line = AgentResume.resumeLine(argv: ["claude"], ref: ref)
        #expect(line == "claude '--continue'")
    }

    @Test("a non-agent command is not ours to resume")
    func nonAgentReturnsNil() {
        #expect(AgentResume.resumeLine(argv: ["ssh", "gate"], ref: nil) == nil)
        #expect(AgentResume.resumeLine(argv: [], ref: nil) == nil)
    }

    @Test("the original flags survive, minus the ones that fight the resume")
    func flagsSurviveExceptResumeFlags() {
        let ref = AgentSessionRef(kind: .claude, id: "abc")
        let argv = ["claude", "--model", "opus", "--continue", "--resume", "old-id", "--fork-session", "-c",
                    "--dangerously-skip-permissions"]
        let line = AgentResume.resumeLine(argv: argv, ref: ref)
        #expect(line == "claude '--resume' 'abc' '--model' 'opus' '--dangerously-skip-permissions'")
    }

    /// A bare `--resume` (the interactive picker) has no id argument to swallow — the next flag must survive.
    @Test("a bare --resume does not eat the following flag")
    func bareResumeKeepsNextFlag() {
        let args = AgentResume.strippedArgs(argv: ["claude", "--resume", "--model", "opus"], kind: .claude)
        #expect(args == ["--model", "opus"])
    }

    @Test("codex's own resume/fork subcommand is stripped with its id")
    func codexSubcommandStripped() {
        #expect(AgentResume.strippedArgs(argv: ["codex", "resume", "old-id", "--search"], kind: .codex)
                == ["--search"])
        #expect(AgentResume.strippedArgs(argv: ["codex", "resume", "--last"], kind: .codex) == [])
        #expect(AgentResume.strippedArgs(argv: ["codex", "fork", "old-id"], kind: .codex) == [])
    }

    /// Behind a launcher the rest of the argv describes the WRAPPER, so it must not be replayed as the
    /// agent's own flags — but the resume itself still happens.
    @Test("a launcher's argv contributes no flags")
    func launcherArgvDropsFlags() {
        let ref = AgentSessionRef(kind: .claude, id: "abc")
        let line = AgentResume.resumeLine(argv: ["sh", "-c", "claude", "--model", "opus"], ref: ref)
        #expect(line == "claude '--resume' 'abc'")
    }

    @Test("a config root with a space or a quote survives quoting")
    func quotingIsPosixSafe() {
        let ref = AgentSessionRef(kind: .claude, id: "abc", configDir: "/Users/x/my dir/.cl'aude")
        let line = AgentResume.resumeLine(argv: ["claude"], ref: ref)
        #expect(line == "env CLAUDE_CONFIG_DIR='/Users/x/my dir/.cl'\\''aude' claude '--resume' 'abc'")
    }
}

@Suite("AgentHookPayload")
struct AgentHookPayloadTests {
    @Test("the session id is read from a real hook payload")
    func parsesSessionID() {
        let json = """
        {"session_id":"7255628b-acba-4c34-affb-5f6dddac4e2b","transcript_path":"/x.jsonl",
         "cwd":"/Users/x/p","hook_event_name":"SessionStart","source":"startup"}
        """
        let payload = AgentHookPayload.parse(Data(json.utf8))
        #expect(payload?.sessionID == "7255628b-acba-4c34-affb-5f6dddac4e2b")
        #expect(payload?.source == "startup")
        #expect(payload?.cwd == "/Users/x/p")
    }

    /// A hook that cannot report an id must degrade to a no-op, never to a throw that fails the agent's turn.
    @Test("garbage, an empty id, and a missing key all parse to nil")
    func badPayloadsParseToNil() {
        #expect(AgentHookPayload.parse(Data("not json".utf8)) == nil)
        #expect(AgentHookPayload.parse(Data()) == nil)
        #expect(AgentHookPayload.parse(Data(#"{"session_id":""}"#.utf8)) == nil)
        #expect(AgentHookPayload.parse(Data(#"{"cwd":"/x"}"#.utf8)) == nil)
    }

    /// A RESUMED claude conversation keeps writing to its ORIGINAL transcript file while stamping new
    /// turns with a FRESH `session_id`, so `claude --resume <session_id>` finds no file. The id to resume
    /// by is the transcript file's stem, which is what `--resume` resolves against.
    @Test("claude resumes by the transcript file stem, not the live session id")
    func claudeResumeIDFromTranscriptPath() {
        let json = """
        {"session_id":"4aa1a235-6973-428b-86d9-f5e406f26a93",
         "transcript_path":"/Users/x/.claude-work/projects/-work/cd355200-a4fa-4bec-aaba-fcb8984cc52e.jsonl",
         "cwd":"/Users/x/work","hook_event_name":"SessionStart","source":"resume"}
        """
        let payload = AgentHookPayload.parse(Data(json.utf8))
        #expect(payload?.resumeID(for: .claude) == "cd355200-a4fa-4bec-aaba-fcb8984cc52e")
    }

    /// Codex resolves `resume <id>` by the session id, NOT by the rollout file name, so its resume id is
    /// the reported `session_id` even when a transcript path is present.
    @Test("codex resumes by its session id, not the rollout file name")
    func codexResumeIDIsSessionID() {
        let json = """
        {"session_id":"019f5c97-8c56-78e1",
         "transcript_path":"/Users/x/.codex/sessions/rollout-2026-07-15-019f5c97.jsonl"}
        """
        let payload = AgentHookPayload.parse(Data(json.utf8))
        #expect(payload?.resumeID(for: .codex) == "019f5c97-8c56-78e1")
    }

    /// Without a transcript path (an older agent, or a payload missing the field) the session id is the
    /// only id we have, so it is the honest fallback rather than nothing.
    @Test("claude falls back to the session id when there is no transcript path")
    func claudeResumeIDFallsBackToSessionID() {
        #expect(AgentHookPayload.parse(Data(#"{"session_id":"abc"}"#.utf8))?.resumeID(for: .claude) == "abc")
        #expect(AgentHookPayload.parse(Data(#"{"session_id":"abc","transcript_path":""}"#.utf8))?
            .resumeID(for: .claude) == "abc")
        #expect(AgentHookPayload.parse(Data(#"{"session_id":"abc","transcript_path":"/tmp/dir/"}"#.utf8))?
            .resumeID(for: .claude) == "dir")
    }
}
