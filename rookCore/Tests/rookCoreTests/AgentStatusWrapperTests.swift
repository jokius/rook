import Foundation
import Testing

// Tests the shipped hook wrapper `rook/Resources/agent-status/rook-agent-status.sh` by running it
// with a stub `rookctl` that records its argv. The two bugs that shipped and broke the live hooks —
// `--socket` placed BEFORE the subcommand (rookctl rejected every call) and stdout leaking into the
// prompt (UserPromptSubmit injects a hook's stdout) — had no test. This is that test. It reaches the
// app target's resource on purpose: the wrapper is the shell half of the rookCore agent-status model.
struct AgentStatusWrapperTests {
    // the shipped wrapper, located relative to this test source file (fixed repo layout).
    private static var wrapper: String {
        URL(fileURLWithPath: #filePath)      // …/rookCore/Tests/rookCoreTests/AgentStatusWrapperTests.swift
            .deletingLastPathComponent()     // rookCoreTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // rookCore
            .deletingLastPathComponent()     // repo root
            .appendingPathComponent("rook/Resources/agent-status/rook-agent-status.sh")
            .path
    }

    // run the wrapper with a stub rookctl. the stub records each received arg on its own line, prints
    // `stubStdout`, and exits `stubExit`. returns the recorded argv, the wrapper's own stdout, and its exit.
    // `stdin` is the hook payload to feed the wrapper on a PIPE (nil = /dev/null, never the inherited
    // stdin: the wrapper's payload inspection branches on whether stdin is a tty).
    private func runWrapper(_ args: [String], env: [String: String],
                            stubStdout: String = "ok", stubExit: Int = 0,
                            stdin: String? = nil) throws -> (argv: [String], stdout: String, exit: Int32) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rook-wrapper-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let record = dir.appendingPathComponent("argv")
        let stub = dir.appendingPathComponent("rookctl")
        let stubScript = """
        #!/bin/bash
        printf '%s\\n' "$@" > '\(record.path)'
        printf '%s' '\(stubStdout)'
        exit \(stubExit)
        """
        try stubScript.write(to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [Self.wrapper] + args
        var fullEnv = env
        fullEnv["ROOKCTL"] = stub.path
        proc.environment = fullEnv
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        if let stdin {
            let input = Pipe()
            proc.standardInput = input
            try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try input.fileHandleForWriting.close()
        } else {
            proc.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        }
        try proc.run()
        proc.waitUntilExit()

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let argv = (try? String(contentsOf: record, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty } ?? []
        return (argv, stdout, proc.terminationStatus)
    }

    @Test func socketComesAfterTheSubcommand() throws {
        let r = try runWrapper(["active"], env: ["ROOK_SESSION_ID": "sid", "ROOK_SOCKET": "/tmp/s.sock"])
        // --socket is a subcommand option, so it MUST follow `session status <state> --target <id>`
        #expect(r.argv == ["session", "status", "active", "--target", "sid", "--socket", "/tmp/s.sock"])
        #expect(r.exit == 0)
    }

    @Test func extraArgsForwardedAfterTargetAndSocket() throws {
        let r = try runWrapper(["blocked", "--blink"], env: ["ROOK_SESSION_ID": "sid", "ROOK_SOCKET": "/tmp/s.sock"])
        #expect(r.argv == ["session", "status", "blocked", "--target", "sid", "--socket", "/tmp/s.sock", "--blink"])
    }

    @Test func noSocketFlagWhenSocketUnset() throws {
        let r = try runWrapper(["active"], env: ["ROOK_SESSION_ID": "sid"])
        #expect(r.argv == ["session", "status", "active", "--target", "sid"])
        #expect(!r.argv.contains("--socket"))
    }

    @Test func noOpOutsideRook() throws {
        // no ROOK_SESSION_ID: must exit 0 and never call rookctl (no recorded argv)
        let r = try runWrapper(["active"], env: [:])
        #expect(r.argv.isEmpty)
        #expect(r.exit == 0)
    }

    @Test func suppressesStdoutSoItCannotPolluteThePrompt() throws {
        // rookctl prints "ok"; the wrapper must swallow it (UserPromptSubmit injects hook stdout)
        let r = try runWrapper(["active"], env: ["ROOK_SESSION_ID": "sid", "ROOK_SOCKET": "/tmp/s.sock"], stubStdout: "ok")
        #expect(r.stdout.isEmpty)
    }

    @Test func alwaysExitsZeroEvenWhenRookctlFails() throws {
        // a status hook must never block the turn, so a non-zero rookctl still yields wrapper exit 0
        let r = try runWrapper(["active"], env: ["ROOK_SESSION_ID": "sid", "ROOK_SOCKET": "/tmp/s.sock"], stubExit: 64)
        #expect(r.exit == 0)
    }

    @Test func paneForwardedWhenRookPaneSet() throws {
        // the app injects ROOK_PANE per surface; the wrapper splices `--pane <value>` before "$@"
        let r = try runWrapper(["blocked"], env: ["ROOK_SESSION_ID": "sid", "ROOK_SOCKET": "/tmp/s.sock", "ROOK_PANE": "right"])
        #expect(r.argv == ["session", "status", "blocked", "--target", "sid", "--socket", "/tmp/s.sock", "--pane", "right"])
        #expect(r.exit == 0)
    }

    @Test func paneForwardedWithoutSocket() throws {
        // no socket branch also carries the pane, right after --target
        let r = try runWrapper(["blocked"], env: ["ROOK_SESSION_ID": "sid", "ROOK_PANE": "scratch"])
        #expect(r.argv == ["session", "status", "blocked", "--target", "sid", "--pane", "scratch"])
    }

    @Test func paneSplicedBeforeExtraArgs() throws {
        // --pane comes before the forwarded "$@" (e.g. --blink), never after
        let r = try runWrapper(["blocked", "--blink"], env: ["ROOK_SESSION_ID": "sid", "ROOK_SOCKET": "/tmp/s.sock", "ROOK_PANE": "right"])
        #expect(r.argv == ["session", "status", "blocked", "--target", "sid", "--socket", "/tmp/s.sock", "--pane", "right", "--blink"])
    }

    @Test func paneOmittedWhenRookPaneUnset() throws {
        // no ROOK_PANE: no --pane flag at all
        let r = try runWrapper(["active"], env: ["ROOK_SESSION_ID": "sid", "ROOK_SOCKET": "/tmp/s.sock"])
        #expect(!r.argv.contains("--pane"))
    }

    @Test func paneNoOpWithoutSessionID() throws {
        // ROOK_PANE set but no ROOK_SESSION_ID: still a no-op, exit 0, no call
        let r = try runWrapper(["active"], env: ["ROOK_PANE": "right"])
        #expect(r.argv.isEmpty)
        #expect(r.exit == 0)
    }

    @Test func paneIDForwardedWithRole() throws {
        // the app injects ROOK_PANE_ID (stable surface token) alongside ROOK_PANE (role); the wrapper
        // forwards both, --pane then --pane-id, so the app can resolve the live slot from the token.
        let r = try runWrapper(["blocked"], env: ["ROOK_SESSION_ID": "sid", "ROOK_SOCKET": "/tmp/s.sock",
                                                  "ROOK_PANE": "right", "ROOK_PANE_ID": "agent-tok"])
        #expect(r.argv == ["session", "status", "blocked", "--target", "sid", "--socket", "/tmp/s.sock",
                           "--pane", "right", "--pane-id", "agent-tok"])
    }

    @Test func paneIDSplicedBeforeExtraArgs() throws {
        // both discriminators come before the forwarded "$@" (e.g. --blink), never after
        let r = try runWrapper(["blocked", "--blink"], env: ["ROOK_SESSION_ID": "sid",
                                                             "ROOK_PANE": "right", "ROOK_PANE_ID": "agent-tok"])
        #expect(r.argv == ["session", "status", "blocked", "--target", "sid",
                           "--pane", "right", "--pane-id", "agent-tok", "--blink"])
    }

    @Test func paneIDForwardedWithoutRole() throws {
        // defensively, a token with no role still forwards --pane-id alone (no --pane)
        let r = try runWrapper(["blocked"], env: ["ROOK_SESSION_ID": "sid", "ROOK_PANE_ID": "agent-tok"])
        #expect(r.argv == ["session", "status", "blocked", "--target", "sid", "--pane-id", "agent-tok"])
    }

    @Test func paneIDOmittedWhenUnset() throws {
        // ROOK_PANE set but no ROOK_PANE_ID: no --pane-id flag
        let r = try runWrapper(["active"], env: ["ROOK_SESSION_ID": "sid", "ROOK_PANE": "right"])
        #expect(!r.argv.contains("--pane-id"))
    }

    // MARK: - a subagent's report is the swarm session's only sign of life
    //
    // Claude Code fires the status hooks inside a subagent too, with the SAME session_id, and the
    // payload carries the subagent's own `agent_type` (absent on the main thread). We used to DROP
    // those reports, because a busy flock of them kept re-asserting `active` over the main thread's
    // `completed`. That filter is gone: measured live, a session running a swarm gets 45 subagent
    // reports a minute and next to nothing from the lead (it is just waiting on them) — dropping them
    // silenced the only evidence the session was alive at all. The `completed`-vs-live race the filter
    // was built for is now settled where it belongs, on the `Stop` payload's `background_tasks`
    // (the section below).

    private static let hookEnv = ["ROOK_SESSION_ID": "sid", "CLAUDECODE": "1"]
    private static let mainPayload = #"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Agent"}"#

    @Test func subagentProgressIsReported() throws {
        // every flavor of subagent seen live — a Task agent, a teammate, a workflow's own agent
        for kind in ["Explore", "general-purpose", "teammate", "workflow-subagent"] {
            let payload = #"{"session_id":"s","hook_event_name":"PostToolUse","agent_id":"a1","agent_type":"\#(kind)"}"#
            let r = try runWrapper(["active", "--blink"], env: Self.hookEnv, stdin: payload)
            #expect(r.argv == ["session", "status", "active", "--target", "sid", "--blink"], "agent_type \(kind)")
            #expect(r.exit == 0)
        }
    }

    @Test func mainThreadProgressStillReported() throws {
        // the main thread's payload has no agent_type at all — it must pass through untouched
        let r = try runWrapper(["active", "--blink"], env: Self.hookEnv, stdin: Self.mainPayload)
        #expect(r.argv == ["session", "status", "active", "--target", "sid", "--blink"])
    }

    @Test func unparseablePayloadStillReports() throws {
        // a payload rook cannot recognize must never silence the indicator
        let r = try runWrapper(["active"], env: Self.hookEnv, stdin: "not json at all")
        #expect(r.argv == ["session", "status", "active", "--target", "sid"])
    }

    // MARK: - live background work
    //
    // `Stop` means the main thread ended its TURN, not that the work is done: a swarm lead hands the
    // turn back while its teammates keep running in the background, and the installed hook's
    // `completed --auto-reset` then lights a "done" checkmark that calls the user over for nothing.
    // The discriminator is the `Stop` payload's own `background_tasks` — per the field's own schema
    // doc, "in-flight background work (running/pending + backgrounded) … lets hooks distinguish
    // 'session is done' from 'session is paused waiting for background work to wake it'".
    //
    // Three `type`s were seen live: `subagent` (Task tool / teammates), `workflow` (the Workflow
    // orchestrator) and `shell` (Bash `run_in_background`). Only the two AGENT kinds count as a live
    // turn — a backgrounded `bun run dev` runs for hours and would pin the row on `active` forever.
    // And liveness is "status is not TERMINAL", not "status == running": the schema names `pending`
    // and `backgrounded` too, while a finished entry vanishes from the array altogether.

    private static func stopPayload(_ tasks: String...) -> String {
        #"{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false,"background_tasks":[\#(tasks.joined(separator: ","))]}"#
    }

    // an agent-ish entry in the shape claude-code 2.1.207 actually emits
    private static func agentTask(_ type: String, _ status: String, agentType: String = "") -> String {
        let agent = agentType.isEmpty ? "" : #","agent_type":"\#(agentType)""#
        return #"{"id":"a652a3537a6bbace4","type":"\#(type)","status":"\#(status)","description":"Read probe.txt and glob all .txt files"\#(agent)}"#
    }

    private static let runningSubagent = agentTask("subagent", "running", agentType: "Explore")
    private static let finishedSubagent = agentTask("subagent", "completed", agentType: "Explore")
    private static let runningWorkflow = agentTask("workflow", "running")
    // a long-running background shell — NOT an agent, so it must never hold the row in `active`
    private static let runningShell =
        #"{"id":"c904ae13f","type":"shell","status":"running","description":"Run the dev server","command":"bun run dev"}"#

    @Test func completedWithLiveSubagentReportsActiveInstead() throws {
        let r = try runWrapper(["completed", "--auto-reset"], env: Self.hookEnv,
                               stdin: Self.stopPayload(Self.runningSubagent))
        #expect(r.argv == ["session", "status", "active", "--target", "sid", "--blink"])
        #expect(!r.argv.contains("--auto-reset"))
    }

    @Test func completedWithLiveWorkflowReportsActiveInstead() throws {
        // REGRESSION: a running Workflow is background work exactly like a subagent, but the first cut
        // of the substitution matched `type == subagent` only — so a `Stop` fired while the Workflow
        // ground on reported "done" and pulled the user over to an unfinished session.
        let r = try runWrapper(["completed", "--auto-reset"], env: Self.hookEnv,
                               stdin: Self.stopPayload(Self.runningWorkflow))
        #expect(r.argv == ["session", "status", "active", "--target", "sid", "--blink"])
    }

    @Test func nonTerminalStatusCountsAsLive() throws {
        // the schema lists `pending` and `backgrounded` alongside `running`; matching `running` alone
        // would call a session done while its queued agents have not even started
        for status in ["running", "pending", "backgrounded"] {
            for type in ["subagent", "workflow"] {
                let r = try runWrapper(["completed", "--auto-reset"], env: Self.hookEnv,
                                       stdin: Self.stopPayload(Self.agentTask(type, status)))
                #expect(r.argv == ["session", "status", "active", "--target", "sid", "--blink"],
                        "\(type)/\(status)")
            }
        }
    }

    @Test func substitutionKeepsTheOtherForwardedFlags() throws {
        // only --auto-reset is dropped (meaningless for `active`); anything else the caller passed rides along
        let r = try runWrapper(["completed", "--auto-reset", "--color", "#ff0000"], env: Self.hookEnv,
                               stdin: Self.stopPayload(Self.runningSubagent))
        #expect(r.argv.prefix(5) == ["session", "status", "active", "--target", "sid"])
        #expect(r.argv.contains("--blink"))
        #expect(!r.argv.contains("--auto-reset"))
        if let i = r.argv.firstIndex(of: "--color") {
            #expect(r.argv.dropFirst(i + 1).first == "#ff0000")
        } else {
            Issue.record("--color was dropped from the forwarded args")
        }
    }

    @Test func terminalStatusStillCompletes() throws {
        // a finished entry is not a live one: the turn really is over
        for status in ["completed", "failed", "cancelled", "stopped"] {
            for type in ["subagent", "workflow"] {
                let r = try runWrapper(["completed", "--auto-reset"], env: Self.hookEnv,
                                       stdin: Self.stopPayload(Self.agentTask(type, status)))
                #expect(r.argv == ["session", "status", "completed", "--target", "sid", "--auto-reset"],
                        "\(type)/\(status)")
            }
        }
    }

    @Test func completedWithOnlyABackgroundShellStillCompletes() throws {
        // a backgrounded `bun run dev` / `tail -f` lives in background_tasks for HOURS — "the array is
        // non-empty" would pin the session in `active` forever, so `type == shell` is NOT live work
        let r = try runWrapper(["completed", "--auto-reset"], env: Self.hookEnv,
                               stdin: Self.stopPayload(Self.runningShell))
        #expect(r.argv == ["session", "status", "completed", "--target", "sid", "--auto-reset"])
    }

    @Test func liveTypeAndLiveStatusInDifferentEntriesIsNotLiveWork() throws {
        // THE trap the per-element parse exists for: `"type":"subagent"` sits on the FINISHED entry and
        // `"status":"running"` on the background shell, so both substrings occur in the payload while no
        // single entry is live work. A grep over the raw JSON says "busy"; the turn is actually done.
        let r = try runWrapper(["completed", "--auto-reset"], env: Self.hookEnv,
                               stdin: Self.stopPayload(Self.runningShell, Self.finishedSubagent))
        #expect(r.argv == ["session", "status", "completed", "--target", "sid", "--auto-reset"])
    }

    @Test func liveEntryFoundBeyondTheFirstIndex() throws {
        // the loop terminator has to keep WALKING: the live subagent sits third, behind a background
        // shell and a finished one. A scan that gives up after index 0 (or breaks on the first
        // not-live entry) would report the checkmark while the swarm is still grinding.
        let r = try runWrapper(["completed", "--auto-reset"], env: Self.hookEnv,
                               stdin: Self.stopPayload(Self.runningShell, Self.finishedSubagent, Self.runningSubagent))
        #expect(r.argv == ["session", "status", "active", "--target", "sid", "--blink"])
    }

    @Test func entryWithoutAStatusKeyCountsAsLive() throws {
        // an agent entry that carries no `status` field at all: deliberately fail-toward-BUSY, since
        // liveness is "not terminal" rather than "== running" — an unknown state is not proof the work
        // finished, and a false `active` costs a stale spinner while a false checkmark calls the user over.
        let noStatus = #"{"id":"a652a3537a6bbace4","type":"subagent","description":"Read probe.txt"}"#
        let r = try runWrapper(["completed", "--auto-reset"], env: Self.hookEnv,
                               stdin: Self.stopPayload(noStatus))
        #expect(r.argv == ["session", "status", "active", "--target", "sid", "--blink"])
    }

    @Test func completedFallsOpenWithoutUsableBackgroundTasks() throws {
        // the ordinary Stop and every unreadable variant of it: nothing to prove work is in flight, so
        // the checkmark stands — an unparseable payload must never park the row on `active`
        let noKey = #"{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false}"#
        for payload in [Self.stopPayload(), noKey, "not json at all", ""] {
            let r = try runWrapper(["completed", "--auto-reset"], env: Self.hookEnv, stdin: payload)
            #expect(r.argv == ["session", "status", "completed", "--target", "sid", "--auto-reset"],
                    "payload \(payload)")
        }
    }

    @Test func liveWorkDoesNotRewriteOtherStates() throws {
        // the substitution is scoped to `completed`; `active`/`blocked` already say the right thing, and
        // `blocked` in particular is a real question waiting on the user — background work never hides it
        for state in ["active", "blocked"] {
            for task in [Self.runningSubagent, Self.runningWorkflow] {
                let r = try runWrapper([state], env: Self.hookEnv, stdin: Self.stopPayload(task))
                #expect(r.argv == ["session", "status", state, "--target", "sid"], "state \(state)")
            }
        }
    }

    @Test func liveWorkIgnoredOutsideAClaudeHook() throws {
        // no $CLAUDECODE (the shell integration, the Codex adapter which parses the same stdin itself,
        // the Pi extension): stdin is never consumed, so no substitution can happen
        for task in [Self.runningSubagent, Self.runningWorkflow] {
            let r = try runWrapper(["completed", "--auto-reset"], env: ["ROOK_SESSION_ID": "sid"],
                                   stdin: Self.stopPayload(task))
            #expect(r.argv == ["session", "status", "completed", "--target", "sid", "--auto-reset"])
        }
    }
}
