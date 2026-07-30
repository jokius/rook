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
    // stdin: the wrapper's subagent filter branches on whether stdin is a tty).
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

    // MARK: - subagent filter
    //
    // Claude Code fires the status hooks inside a subagent too, with the SAME session_id, so a busy
    // flock of subagents used to keep re-asserting `active` over the main thread's `completed`. The
    // hook payload's `agent_type` is the only discriminator: absent on the main thread, the subagent's
    // own type inside one (verified against claude-code 2.1.207: a subagent's PostToolUse carries
    // `"agent_type":"Explore"`, the main thread's carries no such key).

    private static let hookEnv = ["ROOK_SESSION_ID": "sid", "CLAUDECODE": "1"]
    private static let subagentPayload = #"{"session_id":"s","hook_event_name":"PostToolUse","agent_id":"a1","agent_type":"Explore"}"#
    private static let mainPayload = #"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Agent"}"#

    @Test func subagentProgressIsDropped() throws {
        let r = try runWrapper(["active", "--blink"], env: Self.hookEnv, stdin: Self.subagentPayload)
        #expect(r.argv.isEmpty)
        #expect(r.exit == 0)
    }

    @Test func mainThreadProgressStillReported() throws {
        // the main thread's payload has no agent_type at all — it must pass through untouched
        let r = try runWrapper(["active", "--blink"], env: Self.hookEnv, stdin: Self.mainPayload)
        #expect(r.argv == ["session", "status", "active", "--target", "sid", "--blink"])
    }

    @Test func explicitMainAgentTypeStillReported() throws {
        // a build that names the main thread (`main`, `main-session`) must not be mistaken for a subagent
        for kind in ["main", "main-session"] {
            let payload = #"{"session_id":"s","agent_type":"\#(kind)"}"#
            let r = try runWrapper(["active"], env: Self.hookEnv, stdin: payload)
            #expect(r.argv == ["session", "status", "active", "--target", "sid"], "agent_type \(kind)")
        }
    }

    @Test func nestedAgentTypeInBackgroundTasksIsNotASubagent() throws {
        // REGRESSION: the main thread's `Stop` payload lists the session's `background_tasks`, and a
        // BACKGROUNDED subagent's entry there carries its own nested `agent_type`. A substring match read
        // that as "a subagent reported this" and swallowed the `completed` — caught on a live dev instance
        // (the row stayed active+blink after the turn ended), which is why the filter parses the payload
        // instead of grepping it.
        let payload = #"{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false,"background_tasks":[{"id":"t1","agent_type":"Explore","status":"running"}]}"#
        let r = try runWrapper(["completed", "--auto-reset"], env: Self.hookEnv, stdin: payload)
        #expect(r.argv == ["session", "status", "completed", "--target", "sid", "--auto-reset"])
    }

    @Test func subagentBlockedIsStillReported() throws {
        // a subagent's permission prompt is a REAL question waiting on the user: never dropped
        let r = try runWrapper(["blocked"], env: Self.hookEnv, stdin: Self.subagentPayload)
        #expect(r.argv == ["session", "status", "blocked", "--target", "sid"])
    }

    @Test func stdinIsNotReadOutsideAClaudeHook() throws {
        // the shell integration, the Codex adapter (which parses the same stdin itself) and the Pi
        // extension all call the wrapper without $CLAUDECODE: it must not consume their stdin
        let r = try runWrapper(["active", "--blink"], env: ["ROOK_SESSION_ID": "sid"], stdin: Self.subagentPayload)
        #expect(r.argv == ["session", "status", "active", "--target", "sid", "--blink"])
    }

    @Test func unparseablePayloadStillReports() throws {
        // a payload rook cannot recognize must never silence the indicator
        let r = try runWrapper(["active"], env: Self.hookEnv, stdin: "not json at all")
        #expect(r.argv == ["session", "status", "active", "--target", "sid"])
    }
}
