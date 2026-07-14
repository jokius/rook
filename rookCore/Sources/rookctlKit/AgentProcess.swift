import Darwin
import Foundation
import rookCore

/// Finds the agent process that is invoking us, by walking the parent chain.
///
/// A `session.agent` report is only trustworthy if it comes from the agent that actually OWNS the pane.
/// It cannot: an agent can spawn a nested `claude -p`, whose hooks inherit the same `ROOK_SESSION_ID`/
/// `ROOK_PANE` and whose own environment is indistinguishable from the parent's (the agent rewrites
/// `CLAUDE_CODE_SESSION_ID` for its children, so env cannot tell them apart). The chain can:
///
///     hook → claude(nested) → zsh → zsh → claude(pane's own) ← the pane's foreground process
///
/// The NEAREST agent ancestor of the hook is the agent that fired it. The server compares that pid with
/// the pane's live foreground pid and drops any report that does not match, so a nested agent can never
/// overwrite the pane's conversation with its own throwaway one.
enum AgentProcess {
    /// How far up the parent chain to look before giving up — a hook sits a couple of levels under its
    /// agent (`rookctl` → the hook script → the agent), and pid 1 ends the walk anyway.
    private static let maxDepth = 12

    /// The pid of the nearest `claude`/`codex` ancestor of this process, or nil when there is none (rookctl
    /// run by hand from a shell). nil means "unproven": the server then skips the ownership check rather
    /// than rejecting, so a human can still set a ref by hand.
    ///
    /// Each ancestor is classified from its ARGV, not from `kinfo_proc.p_comm`: the executable of a Claude
    /// Code install is `claude.exe` (a bun-compiled binary), so `p_comm` reads `claude.exe` and an exact
    /// name match silently never fires — verified live. Argv is also exactly what the app classifies the
    /// pane's foreground process by (`AgentMonitor` → `AgentKind.classify`), so the two sides agree by
    /// construction.
    static func nearestAgentPid() -> Int? {
        var pid = getppid()
        for _ in 0..<maxDepth {
            guard pid > 1, let info = procInfo(pid) else { return nil }
            if AgentKind.classify(argv: procArgs(pid)) != nil { return Int(pid) }
            pid = info.kp_eproc.e_ppid
        }
        return nil
    }

    /// `sysctl(KERN_PROC_PID)` for one process, or nil when it is gone or not ours to look at.
    private static func procInfo(_ pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info
    }

    /// One process's argv via `sysctl(KERN_PROCARGS2)`, parsed by the host-free `CommandRestore` — the same
    /// two steps the app's `ForegroundProcess` takes for a pane's foreground process.
    private static func procArgs(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return CommandRestore.parseProcArgs(Data(buffer.prefix(size)))
    }
}
