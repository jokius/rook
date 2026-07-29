import Foundation
import Testing
@testable import rookCore

struct CommandRestoreTests {
    /// Builds a synthetic `KERN_PROCARGS2` blob: host-order argc, NUL-terminated exec path, `padding`
    /// extra NULs, then each arg NUL-terminated.
    private func blob(argc: Int32, execPath: String, padding: Int, args: [String]) -> Data {
        var d = withUnsafeBytes(of: argc) { Data($0) } // host byte order, matching parseProcArgs
        d.append(Data(execPath.utf8)); d.append(0)
        d.append(Data(repeating: 0, count: padding))
        for a in args { d.append(Data(a.utf8)); d.append(0) }
        return d
    }

    @Test func parseProcArgsReadsArgvPastExecPathPadding() {
        let data = blob(argc: 2, execPath: "/usr/bin/ssh", padding: 3, args: ["ssh", "gate"])
        #expect(CommandRestore.parseProcArgs(data) == ["ssh", "gate"])
    }

    @Test func parseProcArgsHandlesArgsWithSpaces() {
        let data = blob(argc: 3, execPath: "/usr/bin/ssh", padding: 1,
                        args: ["ssh", "gate", "-t ssh inner"])
        #expect(CommandRestore.parseProcArgs(data) == ["ssh", "gate", "-t ssh inner"])
    }

    @Test func parseProcArgsRejectsTruncatedAndEmpty() {
        #expect(CommandRestore.parseProcArgs(Data()) == nil)
        // argc says 2 but only one arg present -> nil (no overread, no partial result).
        let truncated = blob(argc: 2, execPath: "/bin/sh", padding: 0, args: ["sh"])
        #expect(CommandRestore.parseProcArgs(truncated) == nil)
        // a blob shorter than the argc header.
        #expect(CommandRestore.parseProcArgs(Data([1, 2])) == nil)
    }

    @Test func isKnownShellMatchesShellsAndExtra() {
        #expect(CommandRestore.isKnownShell("zsh"))
        #expect(CommandRestore.isKnownShell("bash"))
        #expect(!CommandRestore.isKnownShell("ssh"))
        #expect(!CommandRestore.isKnownShell("vim"))
        #expect(CommandRestore.isKnownShell("xonsh", extra: "xonsh")) // a non-standard $SHELL basename
        #expect(!CommandRestore.isKnownShell("xonsh", extra: nil))
        // login-shell dash forms: a bare-name argv0 keeps the dash through basename, a path form drops it.
        #expect(CommandRestore.isKnownShell("-zsh"))
        #expect(CommandRestore.isKnownShell("-bash", extra: "bash"))
        #expect(CommandRestore.isKnownShell(CommandRestore.basename("-/bin/zsh"))) // path form -> "zsh"
        // an empty $SHELL basename must not classify an empty argv0 as a shell.
        #expect(!CommandRestore.isKnownShell("", extra: ""))
    }

    @Test func isIdleShellSkipsBarePromptButNotScripts() {
        // a bare interactive/login shell at its prompt is idle (skip).
        #expect(CommandRestore.isIdleShell(argv: ["-zsh"]))
        #expect(CommandRestore.isIdleShell(argv: ["/bin/zsh"]))
        #expect(CommandRestore.isIdleShell(argv: ["-/bin/zsh"]))
        #expect(CommandRestore.isIdleShell(argv: ["zsh", "-i", "-l"]))            // only option flags
        #expect(CommandRestore.isIdleShell(argv: ["bash"], extra: "bash"))
        // a shell RUNNING a script or -c command is NOT idle — capture it (the cld bug).
        #expect(!CommandRestore.isIdleShell(argv: ["/bin/sh", "/usr/local/bin/cld"]))
        #expect(!CommandRestore.isIdleShell(argv: ["/bin/sh", "/usr/local/bin/cld", "--flag"]))
        #expect(!CommandRestore.isIdleShell(argv: ["bash", "-c", "echo hi"]))
        // not a shell at all, or empty.
        #expect(!CommandRestore.isIdleShell(argv: ["htop"]))
        #expect(!CommandRestore.isIdleShell(argv: []))
    }

    @Test func shouldRestoreSkipsDenylistByBasename() {
        let denylist: Set<String> = ["vim", "tmux", "hx"]
        #expect(CommandRestore.shouldRestore(argv: ["ssh", "gate"], denylist: denylist))
        #expect(CommandRestore.shouldRestore(argv: ["top"], denylist: denylist))
        // interpreters / servers are NOT denied (not in the list): usually scripts or servers worth restoring.
        #expect(CommandRestore.shouldRestore(argv: ["python3", "worker.py"], denylist: denylist))
        #expect(CommandRestore.shouldRestore(argv: ["node", "server.js"], denylist: denylist))
        // denylisted entries are matched on the basename.
        #expect(!CommandRestore.shouldRestore(argv: ["/usr/bin/vim", "file"], denylist: denylist))
        #expect(!CommandRestore.shouldRestore(argv: ["tmux"], denylist: denylist))
        #expect(!CommandRestore.shouldRestore(argv: ["/opt/homebrew/bin/hx", "."], denylist: denylist))
        // an empty denylist restores every non-empty argv; an empty argv never restores.
        #expect(CommandRestore.shouldRestore(argv: ["vim", "x"], denylist: []))
        #expect(!CommandRestore.shouldRestore(argv: [], denylist: denylist))
        #expect(!CommandRestore.shouldRestore(argv: [""], denylist: denylist))
    }

    @Test func parseDenylistReadsBasenamesIgnoringCommentsAndBlanks() {
        let text = """
        # programs not to restore
        tmux
          screen\u{0020}\u{0020}
        \u{0020}
        # vim   (commented out, not active)
        zellij
        """
        #expect(CommandRestore.parseDenylist(text) == ["tmux", "screen", "zellij"])
        #expect(CommandRestore.parseDenylist("").isEmpty)
        #expect(CommandRestore.parseDenylist("# only comments\n\n").isEmpty)
    }

    @Test func parseProcArgsRejectsImplausibleArgc() {
        #expect(CommandRestore.parseProcArgs(blob(argc: 0, execPath: "/bin/sh", padding: 0, args: [])) == nil)
        #expect(CommandRestore.parseProcArgs(blob(argc: -1, execPath: "/bin/sh", padding: 1, args: ["sh"])) == nil)
        // argc beyond the sanity cap is rejected before driving a huge reserveCapacity.
        #expect(CommandRestore.parseProcArgs(blob(argc: 5000, execPath: "/bin/sh", padding: 1, args: ["sh", "x"])) == nil)
    }

    @Test func parseProcArgsHandlesEmptyExecPathAndIgnoresEnv() {
        // empty exec path: the exec-path skip is a no-op, the padding skip consumes its NUL.
        #expect(CommandRestore.parseProcArgs(blob(argc: 1, execPath: "", padding: 0, args: ["sh"])) == ["sh"])
        // trailing env bytes after the argc args are ignored (the loop stops at argc).
        var withEnv = blob(argc: 1, execPath: "/bin/sh", padding: 1, args: ["sh"])
        withEnv.append(Data("PATH=/bin".utf8)); withEnv.append(0)
        #expect(CommandRestore.parseProcArgs(withEnv) == ["sh"])
    }

    @Test func parseProcArgsRejectsUnterminatedExecPath() {
        // argc=1 but the bytes after it run to EOF with no NUL: the exec-path walk hits EOF, no args
        // are parsed, and the count mismatch returns nil (no overread).
        var d = withUnsafeBytes(of: Int32(1)) { Data($0) }
        d.append(Data("/bin/shhhhhh".utf8)) // no terminating NUL
        #expect(CommandRestore.parseProcArgs(d) == nil)
    }

    @Test func shellQuotedLineQuotesSpecialChars() {
        #expect(CommandRestore.shellQuotedLine(["ssh", "gate"]) == "'ssh' 'gate'")
        #expect(CommandRestore.shellQuotedLine(["echo", "a b"]) == "'echo' 'a b'")
        #expect(CommandRestore.shellQuotedLine(["echo", "$HOME", "*.txt"]) == "'echo' '$HOME' '*.txt'")
        // an embedded single quote is rendered as '\'' and stays literal.
        #expect(CommandRestore.shellQuotedLine(["echo", "it's"]) == "'echo' 'it'\\''s'")
    }

    @Test func basenameTakesLastPathComponent() {
        #expect(CommandRestore.basename("/usr/bin/vim") == "vim")
        #expect(CommandRestore.basename("ssh") == "ssh")
        #expect(CommandRestore.basename("") == "")
    }

    // MARK: - restorePlan (the surface-seed gate/precedence)

    /// `RestoreInputs` with the two knobs each precedence test actually varies; `restoreOverride` defaults
    /// to nil (no pin), which is the whole pre-override behavior these tests pin down.
    private func inputs(wasRestored: Bool, restoreEnabled: Bool, hadForeground: Bool,
                        foregroundInput: String? = nil, initialCommand: String? = nil,
                        restoreOverride: String? = nil) -> CommandRestore.RestoreInputs {
        CommandRestore.RestoreInputs(wasRestored: wasRestored, restoreEnabled: restoreEnabled,
                                     hadForeground: hadForeground, foregroundInput: foregroundInput,
                                     initialCommand: initialCommand, restoreOverride: restoreOverride)
    }

    @Test func freshCommandSessionAlwaysRunsItsCommand() {
        // a freshly created --command session runs its command via the exec path, toggle irrelevant
        for enabled in [true, false] {
            let plan = CommandRestore.restorePlan(inputs(wasRestored: false, restoreEnabled: enabled,
                                                         hadForeground: false, initialCommand: "ssh host"))
            #expect(plan == CommandRestore.RestorePlan(command: "ssh host", initialInput: nil))
        }
    }

    @Test func restoredCommandSessionRunsCommandOnlyWhenEnabled() {
        let on = CommandRestore.restorePlan(inputs(wasRestored: true, restoreEnabled: true, hadForeground: false,
                                                   initialCommand: "ssh host"))
        #expect(on == CommandRestore.RestorePlan(command: "ssh host", initialInput: nil))
        let off = CommandRestore.restorePlan(inputs(wasRestored: true, restoreEnabled: false, hadForeground: false,
                                                    initialCommand: "ssh host"))
        #expect(off == CommandRestore.RestorePlan(command: nil, initialInput: nil)) // opt-out → plain shell
    }

    @Test func capturedForegroundPreemptsInitialCommand() {
        // a live child captured at quit wins over the persisted creation command (typed, not exec)
        let plan = CommandRestore.restorePlan(inputs(wasRestored: true, restoreEnabled: true, hadForeground: true,
                                                     foregroundInput: "top\n", initialCommand: "ssh host"))
        #expect(plan == CommandRestore.RestorePlan(command: nil, initialInput: "top\n"))
    }

    @Test func suppressedForegroundYieldsPlainShellNotStaleCommand() {
        // a foreground was captured but suppressed (denylisted/off → nil input): a plain shell, NOT a
        // fall-through to the stale creation command
        let plan = CommandRestore.restorePlan(inputs(wasRestored: true, restoreEnabled: true, hadForeground: true,
                                                     initialCommand: "ssh host"))
        #expect(plan == CommandRestore.RestorePlan(command: nil, initialInput: nil))
    }

    @Test func noCommandAndNoForegroundIsPlainShell() {
        let plan = CommandRestore.restorePlan(inputs(wasRestored: true, restoreEnabled: true, hadForeground: false))
        #expect(plan == CommandRestore.RestorePlan(command: nil, initialInput: nil))
    }

    // MARK: - the pinned restore-command override (session.restore)

    @Test func pinnedOverrideBeatsCaptureAndInitialCommand() {
        // the whole point: a pin wins over BOTH the captured foreground and the creation command, and
        // never takes the exec `command` path (so it can't inherit close-on-exit).
        let plan = CommandRestore.restorePlan(inputs(wasRestored: true, restoreEnabled: true, hadForeground: true,
                                                     foregroundInput: "top\n", initialCommand: "ssh host",
                                                     restoreOverride: "cd api && npm run dev"))
        #expect(plan == CommandRestore.RestorePlan(command: nil, initialInput: "cd api && npm run dev\n"))
    }

    @Test func pinnedCommandIsTypedVerbatimNotShellQuoted() {
        // a pin is a shell LINE, so the pipeline/redirect/&& survive as written — this is what fixes the
        // documented "compound lines don't restore" limitation of the argv capture.
        let line = "tail -f log | grep -i err > /tmp/e 2>&1"
        let plan = CommandRestore.restorePlan(inputs(wasRestored: true, restoreEnabled: true, hadForeground: false,
                                                     restoreOverride: line))
        #expect(plan.initialInput == line + "\n")
        #expect(plan.initialInput != CommandRestore.shellQuotedLine([line]) + "\n")
    }

    @Test func pinnedToNothingSuppressesCaptureAndInitialCommand() {
        // `""` is the third state: a plain shell, distinct from "no pin" which would restore the capture.
        let plan = CommandRestore.restorePlan(inputs(wasRestored: true, restoreEnabled: true, hadForeground: true,
                                                     foregroundInput: "top\n", initialCommand: "ssh host",
                                                     restoreOverride: ""))
        #expect(plan == CommandRestore.RestorePlan(command: nil, initialInput: nil))
    }

    @Test func noPinLeavesTheCapturePathUntouched() {
        // nil override == the pre-feature behavior, so an old snapshot (no key → nil) restores identically.
        let plan = CommandRestore.restorePlan(inputs(wasRestored: true, restoreEnabled: true, hadForeground: true,
                                                     foregroundInput: "top\n", restoreOverride: nil))
        #expect(plan == CommandRestore.RestorePlan(command: nil, initialInput: "top\n"))
    }

    @Test func pinObeysTheRestoreToggle() {
        // the global "restore running commands" switch is the master gate: off restores NOTHING, pin
        // included — and it must not fall through to the capture or the creation command either.
        let plan = CommandRestore.restorePlan(inputs(wasRestored: true, restoreEnabled: false, hadForeground: true,
                                                     foregroundInput: "top\n", initialCommand: "ssh host",
                                                     restoreOverride: "npm run dev"))
        #expect(plan == CommandRestore.RestorePlan(command: nil, initialInput: nil))
    }

    @Test func restoreInputPrefersPinOverCapture() {
        // the split pane's whole decision (no initialCommand there), so it is tested directly too.
        #expect(CommandRestore.restoreInput(restoreEnabled: true, restoreOverride: "htop",
                                            capturedInput: "top\n") == "htop\n")
        #expect(CommandRestore.restoreInput(restoreEnabled: true, restoreOverride: "",
                                            capturedInput: "top\n") == nil)
        #expect(CommandRestore.restoreInput(restoreEnabled: true, restoreOverride: nil,
                                            capturedInput: "top\n") == "top\n")
        #expect(CommandRestore.restoreInput(restoreEnabled: false, restoreOverride: "htop",
                                            capturedInput: "top\n") == nil)
        // toggle off with NO pin: the captured input arrives already gated app-side, so it passes through
        // unchanged rather than being re-gated here.
        #expect(CommandRestore.restoreInput(restoreEnabled: false, restoreOverride: nil,
                                            capturedInput: nil) == nil)
    }
}
