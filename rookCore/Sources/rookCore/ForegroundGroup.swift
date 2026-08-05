import Foundation

/// Pure, host-free half of reading a pane's foreground process: picking which member of a process GROUP
/// actually names the program, and normalizing the login dash off argv[0]. The app target owns the two
/// `sysctl` calls (`KERN_PROCARGS2`, `KERN_PROC_PGRP`) and defers every judgement here, the same split
/// `CommandRestore` already has for the parse and the shell detection.
///
/// Both helpers exist for ONE defect: libghostty's `foreground_pid` is `tcgetpgrp`, a process GROUP id.
/// Under a job-control shell each job gets its own group, so the leader IS the program; a pane with no
/// job-control shell (a `--command` session) leaves its program in the group led by setuid-root `login`,
/// whose argv `KERN_PROCARGS2` refuses for a non-root caller (measured: `EINVAL`), and the pane read as
/// idle.
public enum ForegroundGroup {
    /// One process-group member as `KERN_PROC_PGRP` reports it: its own pid and its parent's.
    public struct Member: Equatable, Sendable {
        public let pid: Int32
        public let ppid: Int32
        public init(pid: Int32, ppid: Int32) {
            self.pid = pid
            self.ppid = ppid
        }
    }

    /// The pids to try when a process group's LEADER argv is unreadable: the leader's own children, lowest
    /// pid first. A `--command` pane's program is `login`'s direct child (the login shell `exec`s it), so
    /// that child is the real answer.
    ///
    /// Only DIRECT children qualify while the leader is alive, and PARENTAGE — not pid order — is what
    /// decides. A pipeline under a job-control shell puts every element in one group led by the first while
    /// parenting them all to the shell, so `sudo tail … | grep …` must not report `grep`, a SIBLING of the
    /// leader rather than its child. Ordering on pid alone would also pick the wrong process once macOS
    /// recycles pids past 99999, where a freshly forked grandchild sorts below the program that spawned it.
    ///
    /// A leader that has already EXITED is the exception: `cat f | less` keeps the group id of the reaped
    /// `cat`, so no survivor is its child and the parentage test would report a live pane as idle. With no
    /// leader in the group there is nothing to check parentage against, so every survivor qualifies.
    public static func descentCandidates(pgid: Int32, members: [Member]) -> [Int32] {
        let others = members.filter { $0.pid != pgid && $0.pid > 0 }
        guard members.contains(where: { $0.pid == pgid }) else { return others.map(\.pid).sorted() }
        return others.filter { $0.ppid == pgid }.map(\.pid).sorted()
    }

    /// Drop the leading `-` macOS dash-marks a login process's argv[0] with, so the argv names a program
    /// that can actually be rendered and re-run (`-sleep` → `sleep`). Only argv[0] carries the mark, and
    /// only the mark is removed: a path form (`-/bin/zsh`) keeps the rest of the path.
    public static func stripLoginDash(_ argv: [String]) -> [String] {
        guard let first = argv.first, first.hasPrefix("-") else { return argv }
        var result = argv
        result[0] = String(first.dropFirst())
        return result
    }
}
