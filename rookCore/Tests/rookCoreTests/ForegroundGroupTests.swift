import Foundation
import Testing
@testable import rookCore

/// The process-group semantics are invisible from every level above (the tree read hands back an argv
/// either way), so the selection rule is pinned here rather than at the control-API level.
struct ForegroundGroupTests {
    private func member(_ pid: Int32, _ ppid: Int32) -> ForegroundGroup.Member { .init(pid: pid, ppid: ppid) }

    @Test func descentKeepsOnlyTheLeadersChildrenLowestFirst() {
        #expect(ForegroundGroup.descentCandidates(
            pgid: 100, members: [member(100, 9), member(102, 100), member(101, 100)]) == [101, 102])
        #expect(ForegroundGroup.descentCandidates(pgid: 100, members: [member(100, 9)]).isEmpty)
        #expect(ForegroundGroup.descentCandidates(pgid: 100, members: []).isEmpty)
        #expect(ForegroundGroup.descentCandidates(
            pgid: 100, members: [member(0, 100), member(-1, 100), member(101, 100)]) == [101])
    }

    @Test func descentSkipsAPipelineSiblingOfASetuidLeader() {
        // a pipeline parents every element to the SHELL while the group leads on the first, so `grep` is a
        // sibling of the setuid leader, not the pane's foreground.
        #expect(ForegroundGroup.descentCandidates(pgid: 100, members: [member(100, 9), member(101, 9)]).isEmpty)
    }

    @Test func descentRanksByParentageNotPidOrder() {
        // a grandchild that took a low pid after the 99999 wrap must not outrank its own parent.
        #expect(ForegroundGroup.descentCandidates(
            pgid: 100, members: [member(100, 9), member(99500, 100), member(500, 99500)]) == [99500])
    }

    @Test func descentAcceptsEverySurvivorOnceTheLeaderIsReaped() {
        // `cat f | less` keeps the reaped `cat`'s group id, so there is nothing to check parentage against.
        #expect(ForegroundGroup.descentCandidates(pgid: 100, members: [member(101, 9)]) == [101])
        #expect(ForegroundGroup.descentCandidates(
            pgid: 100, members: [member(102, 9), member(101, 9)]) == [101, 102])
    }

    /// The sidebar agent logo reads a pane through the SAME descent (`AgentMonitor` → `ForegroundProcess
    /// .running` → `AgentKind.classify`), and a `--command` pane is exactly where the two meet: measured
    /// live, `login -flp <user> /bin/bash --noprofile --norc -c 'exec -l <cmd>'` leaves the program in
    /// login's group with argv[0] dash-marked (`-sleep 900`), so an agent there arrives as `-claude`.
    /// `classify` matches the argv[0] BASENAME exactly, so the dash is not cosmetic — drop the strip and the
    /// logo silently goes back to the terminal glyph for every `--command` agent pane.
    @Test func aDescendedCommandPaneClassifiesOnceTheLoginDashIsStripped() {
        let raw = ["-claude", "--resume", "6c7aeb7e"]
        #expect(AgentKind.classify(argv: raw) == nil)
        #expect(AgentKind.classify(argv: ForegroundGroup.stripLoginDash(raw)) == .claude)
        #expect(AgentKind.classify(argv: ForegroundGroup.stripLoginDash(["-codex"])) == .codex)
        // and the descent still reports a plain login shell as the idle shell it is, never an agent.
        #expect(AgentKind.classify(argv: ForegroundGroup.stripLoginDash(["-/bin/zsh"])) == nil)
    }

    @Test func stripLoginDashDropsOnlyTheMark() {
        #expect(ForegroundGroup.stripLoginDash(["-sleep", "900"]) == ["sleep", "900"])
        #expect(ForegroundGroup.stripLoginDash(["-/bin/zsh"]) == ["/bin/zsh"])
        #expect(ForegroundGroup.stripLoginDash(["sleep", "900"]) == ["sleep", "900"])
        #expect(ForegroundGroup.stripLoginDash(["git", "-C", "/tmp", "status"]) == ["git", "-C", "/tmp", "status"])
        #expect(ForegroundGroup.stripLoginDash([]) == [])
        #expect(ForegroundGroup.stripLoginDash(["-"]) == [""])
    }
}
