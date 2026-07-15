import Foundation
import Testing

/// The three agent-status hook scripts are entry points Claude Code / Codex invoke via
/// `/bin/sh -c '<path> …'`, which needs the exec bit: a script shipped 0644 dies with "Permission
/// denied" — SILENTLY, since a hook failure is non-blocking — so the hook never runs.
/// `rook-agent-session.sh` once shipped without it (git mode 100644) and the whole
/// `session.agent` / resume-agent-conversations feature went dark. Guard every hook script's exec bit
/// here so a stray 0644 commit fails the suite instead of shipping a dead hook.
@Suite("Hook scripts are executable")
struct HookScriptsExecutableTests {
    /// The bundled scripts folder, resolved from this test file up to the repo root (mirrors
    /// `CodexStatusHookTests`, which runs the real Codex script from the same folder).
    private static var scriptsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // rookCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // rookCore
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("rook/Resources/agent-status")
    }

    @Test("every bundled agent-status hook script has its owner exec bit",
          arguments: ["rook-agent-status.sh", "rook-codex-status.sh", "rook-agent-session.sh"])
    func hookScriptIsExecutable(_ name: String) throws {
        let path = Self.scriptsDir.appendingPathComponent(name).path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        #expect(mode & 0o100 != 0, "\(name) must be executable — mode is 0\(String(mode, radix: 8))")
    }
}
