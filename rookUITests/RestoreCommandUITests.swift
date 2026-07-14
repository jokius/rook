import Darwin
import XCTest

/// End-to-end for the restore-running-command feature: capture a pane's foreground command at quit and
/// re-run it on relaunch. The marker is `tee <file>` — a NON-shell process (so it isn't filtered as a
/// shell prompt) that creates its output file on start and blocks reading the terminal. Re-running it
/// recreates the file, so a delete-then-relaunch-then-exists cycle is the observable proof of re-run.
@MainActor
final class RestoreCommandUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!
    private var marker: URL!
    private var socketPath: String!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rook-uitest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        marker = stateDir.appendingPathComponent("restore-marker")
        app = XCUIApplication()
        app.launchEnvironment["ROOK_STATE_DIR"] = stateDir.path
        // short socket path in the runner's temp dir: under the ~104-byte sun_path limit AND inside the
        // runner sandbox (the long per-test stateDir subdir + /tmp both fail); used to create a --command
        // session over the control channel.
        socketPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("rookr-\(UUID().uuidString.prefix(8)).sock")
        app.launchEnvironment["ROOK_CONTROL_SOCKET"] = socketPath
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
        if let socketPath { try? FileManager.default.removeItem(atPath: socketPath) }
    }

    func testRestoreReRunsForegroundCommand() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        runTeeMarker()

        // delete the marker, quit (applicationWillTerminate captures the foreground `tee`), relaunch.
        try FileManager.default.removeItem(at: marker)
        gracefulQuit()
        app.launchForUITest()

        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) },
                      "restore should re-run the captured foreground `tee` command and recreate the marker")
    }

    func testRestoreOffDoesNotReRun() throws {
        seedRestoreFlag(false)
        app.launchForUITest()
        runTeeMarker()

        try FileManager.default.removeItem(at: marker)
        gracefulQuit()
        app.launchForUITest()

        // flag off → nothing captured at quit → `tee` is not re-run → the marker stays gone.
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "session restored")
        RunLoop.current.run(until: Date().addingTimeInterval(2)) // give any (incorrect) re-run a chance to fire
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "with the flag off, the foreground command must not be re-run")
    }

    func testRestoreReRunsShellScriptWrapper() throws {
        // a shell RUNNING a command (argv0 a shell WITH a payload arg) must be captured, not skipped as an
        // idle prompt. The real `cld` claude-code launcher is a `#!/bin/sh` wrapper whose foreground is
        // `/bin/sh <script>`; this uses `sh -c 'tee …; true'` (a compound list, so sh stays the foreground
        // with a payload arg) because the XCUITest runner can't drop an executable script the sandboxed app
        // is allowed to run. Same isIdleShell path: a shell with a payload is captured.
        seedRestoreFlag(true)
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session row")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeText("sh -c 'tee \(marker.path); true'\n")
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) },
                      "the `sh -c` wrapper's tee should create the marker on start")

        try FileManager.default.removeItem(at: marker)
        gracefulQuit()
        app.launchForUITest()
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) },
                      "restore should re-run the captured `sh -c` wrapper and recreate the marker")
    }

    func testRestoreSkipsIdleShellPane() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        // leave the pane at its prompt (no command run), then quit. Capture runs (flag on), but the idle
        // login shell — argv0 `-/bin/zsh`, recognized by isKnownShell — must NOT be captured as a command.
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        gracefulQuit()
        XCTAssertTrue(capturedForegroundCommands().isEmpty,
                      "an idle login-shell pane must not be captured as a foreground command, got \(capturedForegroundCommands())")
    }

    // A `session.new --command` session persists its command and re-runs it via the EXEC path on restore
    // when the feature is on — the command-session analogue of the foreground path. `tee <marker>` as the
    // command exec-replaces the shell (so libghostty reports no foreground and NOTHING is captured), which
    // proves the restore comes from the persisted `initialCommand`, not a captured foreground.
    func testRestoreReRunsCommandSession() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 30), "control server up")
        let created = try sendCommand(#"{"cmd":"session.new","args":{"command":"tee \#(marker.path)"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "session.new --command should succeed: \(created)")
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) },
                      "the --command `tee` should create its marker on start")

        try FileManager.default.removeItem(at: marker)
        gracefulQuit()
        app.launchForUITest()
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) },
                      "restore should re-run the persisted --command (via the exec path) and recreate the marker")
    }

    func testRestoreOffLeavesCommandSessionAPlainShell() throws {
        seedRestoreFlag(false)
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 30), "control server up")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.new","args":{"command":"tee \#(marker.path)"}}"#)["ok"] as? Bool,
                       true, "session.new --command should succeed")
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) }, "marker created on start")

        try FileManager.default.removeItem(at: marker)
        gracefulQuit()
        app.launchForUITest()
        // flag off → a restored --command session comes back a plain shell → tee is not re-run → marker gone.
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "session restored")
        RunLoop.current.run(until: Date().addingTimeInterval(2)) // give any (incorrect) re-run a chance to fire
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "with the flag off, a restored --command session must not re-run its command")
    }

    // MARK: - Agent conversations (session.agent + resumeAgentSessions)

    /// The whole point of the feature: a restored agent pane must come back on the SAME conversation. The
    /// pane's foreground is a `tee` renamed to `claude` via `exec -a` (the classifier keys on argv[0], and
    /// the sandboxed app can't be handed a real executable to run), and the conversation is reported over
    /// the socket exactly as the agent's SessionStart hook would.
    func testRestoreResumesAgentConversation() throws {
        let conversation = UUID().uuidString
        seedRestoreFlags(restore: true, resumeAgents: true)
        app.launchForUITest()
        runFakeAgent()

        let reported = try sendCommand(#"""
        {"cmd":"session.agent","args":{"agent":"claude","agentID":"\#(conversation)","configDir":"/tmp/cfg"}}
        """#)
        XCTAssertEqual(reported["ok"] as? Bool, true, "the hook's report should be accepted: \(reported)")

        gracefulQuit()
        // the conversation must be PERSISTED (with its config root) alongside the captured foreground
        let refs = persistedAgentSessions()
        XCTAssertEqual(refs.first?["id"] as? String, conversation, "the conversation should persist, got \(refs)")
        XCTAssertEqual(refs.first?["kind"] as? String, "claude")
        XCTAssertEqual(refs.first?["configDir"] as? String, "/tmp/cfg")

        app.launchForUITest()
        let screen = try restoredPaneText()
        XCTAssertTrue(screen.contains("--resume") && screen.contains(conversation),
                      "the restored pane should resume THAT conversation, got: \(screen)")
        XCTAssertTrue(screen.contains("CLAUDE_CONFIG_DIR=/tmp/cfg") || screen.contains("CLAUDE_CONFIG_DIR='/tmp/cfg'"),
                      "the resume should run against the profile the conversation lives in, got: \(screen)")
    }

    /// With the resume toggle off, the pane still re-runs its agent (the restore flag is on) — but bare,
    /// onto a fresh conversation. This is the pre-feature behavior, and it must not regress.
    func testRestoreWithoutResumeFlagRunsBareAgent() throws {
        seedRestoreFlags(restore: true, resumeAgents: false)
        app.launchForUITest()
        runFakeAgent()
        _ = try sendCommand(#"""
        {"cmd":"session.agent","args":{"agent":"claude","agentID":"\#(UUID().uuidString)"}}
        """#)

        gracefulQuit()
        app.launchForUITest()
        let screen = try restoredPaneText()
        XCTAssertFalse(screen.contains("--resume"),
                       "with the resume toggle off the agent must come back bare, got: \(screen)")
    }

    /// A NESTED agent (a `claude -p` the pane's own agent spawned) inherits the same ROOK_SESSION_ID and
    /// would otherwise overwrite the pane's conversation with its own throwaway one. The report carries the
    /// reporting agent's pid; one that isn't the pane's foreground process is dropped.
    func testAgentReportFromANonForegroundAgentIsIgnored() throws {
        seedRestoreFlags(restore: true, resumeAgents: true)
        app.launchForUITest()
        runFakeAgent()

        // pid 1 (launchd) is never the pane's foreground process — stands in for the nested agent
        let response = try sendCommand(#"""
        {"cmd":"session.agent","args":{"agent":"claude","agentID":"\#(UUID().uuidString)","agentPid":1}}
        """#)
        XCTAssertEqual(response["ok"] as? Bool, true, "a hook must never fail the agent's turn")
        gracefulQuit()
        XCTAssertTrue(persistedAgentSessions().isEmpty,
                      "a report from a non-foreground agent must not be remembered, got \(persistedAgentSessions())")
    }

    // MARK: - Helpers

    /// Seed both restore flags into the isolated `settings.json`, and point HOME at the isolated state dir
    /// so the restored login shell can't find the REAL `claude` on the user's PATH — the resume line then
    /// stays legible in the scrollback instead of a live agent TUI repainting over it.
    private func seedRestoreFlags(restore: Bool, resumeAgents: Bool) {
        let json = #"{"restoreRunningCommand":\#(restore),"resumeAgentSessions":\#(resumeAgents)}"#
        try? Data(json.utf8).write(to: stateDir.appendingPathComponent("settings.json"))
        app.launchEnvironment["HOME"] = stateDir.path
    }

    /// Run a fake agent as the pane's foreground: `exec -a claude tee <marker>` renames `tee`'s argv[0] to
    /// `claude`, which is exactly what `AgentKind.classify` keys on — and `tee` blocks on the terminal, so
    /// it is still the foreground process at quit. (zsh's `exec -a`; the login shell here is the user's.)
    private func runFakeAgent() {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 30), "seeded session row")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeText("exec -a claude tee \(marker.path)\n")
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) },
                      "the fake agent should create its marker on start (terminal must be focused)")
    }

    /// Every persisted `agentSession` across the window snapshots written at quit.
    private func persistedAgentSessions() -> [[String: Any]] {
        let windowsDir = stateDir.appendingPathComponent("windows")
        guard let files = try? FileManager.default.contentsOfDirectory(at: windowsDir, includingPropertiesForKeys: nil)
        else { return [] }
        var result: [[String: Any]] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let workspaces = obj["workspaces"] as? [[String: Any]] else { continue }
            for ws in workspaces {
                for s in (ws["sessions"] as? [[String: Any]]) ?? [] {
                    if let ref = s["agentSession"] as? [String: Any] { result.append(ref) }
                }
            }
        }
        return result
    }

    /// The restored pane's visible buffer — the line rook typed into the shell on restore.
    private func restoredPaneText() throws -> String {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 30), "session restored")
        RunLoop.current.run(until: Date().addingTimeInterval(2)) // let initial_input reach the shell
        let response = try sendCommand(#"{"cmd":"session.text","args":{"lines":20}}"#)
        let result = response["result"] as? [String: Any]
        return (result?["text"] as? String) ?? ""
    }

    /// Every persisted `foregroundCommand` across the window snapshots written at quit (the capture oracle).
    private func capturedForegroundCommands() -> [[String]] {
        let windowsDir = stateDir.appendingPathComponent("windows")
        guard let files = try? FileManager.default.contentsOfDirectory(at: windowsDir, includingPropertiesForKeys: nil)
        else { return [] }
        var result: [[String]] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let workspaces = obj["workspaces"] as? [[String: Any]] else { continue }
            for ws in workspaces {
                for s in (ws["sessions"] as? [[String: Any]]) ?? [] {
                    if let fg = s["foregroundCommand"] as? [String] { result.append(fg) }
                    if let fg = s["splitForegroundCommand"] as? [String] { result.append(fg) }
                }
            }
        }
        return result
    }

    /// Seed `restoreRunningCommand` into the isolated `settings.json` before launch.
    private func seedRestoreFlag(_ on: Bool) {
        let json = #"{"restoreRunningCommand":\#(on)}"#
        try? Data(json.utf8).write(to: stateDir.appendingPathComponent("settings.json"))
    }

    /// Type `tee <marker>` into the focused terminal and confirm it created the marker (so it is the live
    /// foreground process — `tee` opens its output file on start, then blocks reading the terminal).
    private func runTeeMarker() {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session row")
        RunLoop.current.run(until: Date().addingTimeInterval(1)) // let the shell reach its prompt
        app.typeText("tee \(marker.path)\n")
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) },
                      "the foreground `tee` should create its marker file on start (terminal must be focused)")
    }

    /// Quit via ⌘Q so `applicationWillTerminate` fires the capture. `XCUIApplication.terminate()` hard-kills
    /// and skips it; the quit-confirm modal is auto-skipped under XCUITest.
    private func gracefulQuit() {
        app.typeKey("q", modifierFlags: .command)
        _ = app.wait(for: .notRunning, timeout: 10)
    }

    private func poll(_ condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }

    /// Send one newline-delimited JSON request to the control socket and return the decoded response.
    private func sendCommand(_ line: String) throws -> [String: Any] {
        let fd = try connect(to: socketPath)
        defer { close(fd) }
        var payload = Data(line.utf8)
        payload.append(UInt8(ascii: "\n"))
        try writeAll(fd, payload)
        let data = readResponseLine(fd)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(obj, "response should be a JSON object, got: \(String(data: data, encoding: .utf8) ?? "<binary>")")
    }

    private func connect(to path: String) throws -> Int32 {
        guard path.utf8.count < 104 else { // sun_path limit; guard before copying, like SocketClient.connect
            throw posixError("socket path too long (\(path.utf8.count) bytes)", ENAMETOOLONG)
        }
        let deadline = Date().addingTimeInterval(15)
        var lastErrno: Int32 = 0
        repeat {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw posixError("socket", errno) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = path.utf8CString
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buf in
                    pathBytes.withUnsafeBufferPointer { src in buf.update(from: src.baseAddress!, count: src.count) }
                }
            }
            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { return fd }
            lastErrno = errno
            close(fd)
            usleep(200_000)
        } while Date() < deadline
        throw posixError("connect(\(path))", lastErrno)
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < data.count {
                let n = write(fd, base + offset, data.count - offset)
                if n <= 0 { throw posixError("write", errno) }
                offset += n
            }
        }
    }

    private func readResponseLine(_ fd: Int32) -> Data {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n < 0 {
                if errno == EINTR { continue } // a signal interrupted the blocking read; retry
                return buffer
            }
            if n == 0 { return buffer } // EOF
            if byte == UInt8(ascii: "\n") { return buffer }
            buffer.append(byte)
        }
    }

    private func posixError(_ op: String, _ code: Int32) -> NSError {
        NSError(domain: "control-socket", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "\(op) failed: \(String(cString: strerror(code)))"])
    }
}
