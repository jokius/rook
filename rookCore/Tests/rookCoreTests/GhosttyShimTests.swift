import Foundation
import Testing

// The `ghostty +ssh-cache` shim bundled at Contents/MacOS/ghostty. Its only caller is ghostty's
// own shell-integration ssh() wrapper, which reads ONLY the exit code — 0 means "this host already
// has our terminfo, skip the upload" — so that contract is what these exercise.
struct GhosttyShimTests {
    private static var shim: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rook/Resources/ghostty-shim.sh")
            .path
    }

    private func run(_ args: [String], stateDir: URL) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [Self.shim] + args
        proc.environment = ["ROOK_STATE_DIR": stateDir.path, "PATH": "/usr/bin:/bin"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try! proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    private func withStateDir(_ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rook-shim-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try body(dir)
    }

    @Test func unknownHostMissesThenHitsAfterAdd() throws {
        try withStateDir { dir in
            #expect(run(["+ssh-cache", "--host=me@host"], stateDir: dir) != 0)
            #expect(run(["+ssh-cache", "--add=me@host"], stateDir: dir) == 0)
            #expect(run(["+ssh-cache", "--host=me@host"], stateDir: dir) == 0)
        }
    }

    // A cached host must not make its neighbours look cached: the wrapper would then skip the
    // upload and hand a stock host TERM=xterm-ghostty, which is exactly the broken-nano case.
    @Test func matchIsWholeLineNotSubstring() throws {
        try withStateDir { dir in
            #expect(run(["+ssh-cache", "--add=me@host"], stateDir: dir) == 0)
            #expect(run(["+ssh-cache", "--host=me@host2"], stateDir: dir) != 0)
            #expect(run(["+ssh-cache", "--host=host"], stateDir: dir) != 0)
        }
    }

    @Test func addIsIdempotent() throws {
        try withStateDir { dir in
            for _ in 0..<3 { #expect(run(["+ssh-cache", "--add=me@host"], stateDir: dir) == 0) }
            let cache = try String(contentsOf: dir.appendingPathComponent("ssh-terminfo-hosts"), encoding: .utf8)
            #expect(cache == "me@host\n")
        }
    }

    // A GHOSTTY_REV bump brings the rewritten wrapper, which calls `+ssh -- <args>` and has no
    // fallback of its own — the shim must still connect rather than fail the user's ssh.
    @Test func sshFallsBackToPlainSSH() throws {
        try withStateDir { dir in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            // a fake `ssh` on PATH records what it was exec'd with, so this asserts the arg
            // splitting (everything after `--`) without opening a connection.
            let fakeBin = dir.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
            let log = dir.appendingPathComponent("ssh-args")
            let fakeSSH = fakeBin.appendingPathComponent("ssh")
            try "#!/bin/sh\nprintf '%s\\n' \"$*\" > '\(log.path)'\n".write(to: fakeSSH, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)

            proc.arguments = [Self.shim, "+ssh", "--terminfo=false", "--", "-p", "22", "me@host", "uptime"]
            proc.environment = ["ROOK_STATE_DIR": dir.path, "PATH": "\(fakeBin.path):/usr/bin:/bin"]
            try proc.run()
            proc.waitUntilExit()
            #expect(proc.terminationStatus == 0)
            #expect(try String(contentsOf: log, encoding: .utf8) == "-p 22 me@host uptime\n")
        }
    }

    // Not a ghostty: anything but the two ssh arms fails instead of pretending to be the real binary.
    @Test func nonCacheInvocationsFail() throws {
        try withStateDir { dir in
            #expect(run([], stateDir: dir) != 0)
            #expect(run(["+list-themes"], stateDir: dir) != 0)
            #expect(run(["+ssh-cache"], stateDir: dir) != 0)
            #expect(run(["+ssh-cache", "--clear"], stateDir: dir) != 0)
        }
    }
}
