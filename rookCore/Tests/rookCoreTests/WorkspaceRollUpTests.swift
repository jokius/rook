import Foundation
import Testing
@testable import rookCore

/// The andon roll-up: the agent-status glyph a COLLAPSED workspace row wears for its "worst" child
/// (`Workspace.rollUpIndicator`, ordered by `AgentStatus.rollUpRank`), so a blocked agent inside a folded
/// workspace stays visible. Black box against the documented contract — the gate on VISUAL collapse lives
/// app-side in the sidebar row builder and is covered by `SidebarRollUpUITests`; here the workspace is asked
/// for its roll-up unconditionally.
///
/// The fixture style is `WorkspaceTests`' `unseenCount` roll-up: plain `Session(initialCwd:)` values in a
/// `Workspace`, since a roll-up is a pure function of the sessions it holds.
@MainActor
struct WorkspaceRollUpTests {
    // MARK: - the rank

    // blocked > completed > active > idle, lower wins. Pinned by ORDER rather than by literal ints: the
    // contract says "lower wins", not which numbers carry it.
    @Test func rollUpRankOrdersBlockedThenCompletedThenActiveThenIdle() {
        #expect(AgentStatus.blocked.rollUpRank < AgentStatus.completed.rollUpRank)
        #expect(AgentStatus.completed.rollUpRank < AgentStatus.active.rollUpRank)
        #expect(AgentStatus.active.rollUpRank < AgentStatus.idle.rollUpRank)
        // the transitive pairs spelled out, so a half-ordered rank can't hide behind the chain above
        #expect(AgentStatus.blocked.rollUpRank < AgentStatus.active.rollUpRank)
        #expect(AgentStatus.blocked.rollUpRank < AgentStatus.idle.rollUpRank)
        #expect(AgentStatus.completed.rollUpRank < AgentStatus.idle.rollUpRank)
        // every state is distinguishable, so no two statuses can ever tie on rank
        #expect(Set(AgentStatus.allCases.map(\.rollUpRank)).count == AgentStatus.allCases.count)
    }

    // the whole reason `rollUpRank` exists as its own thing: it is DELIBERATELY NOT `attentionRank`.
    // `attentionRank` puts `active` ABOVE `completed` because it drives the attention QUEUE (what to look at
    // next); a roll-up answers "the most important thing inside", where a FINISHED run outranks one still
    // working. This is the test that fails if the two are ever "de-duplicated" into one rank.
    @Test func rollUpRankIsNotAttentionRankForActiveVersusCompleted() {
        #expect(AgentStatus.active.attentionRank < AgentStatus.completed.attentionRank)
        #expect(AgentStatus.completed.rollUpRank < AgentStatus.active.rollUpRank)
        // they do agree on the two ends: blocked is the most important state, idle the least
        #expect(AgentStatus.blocked.rollUpRank == AgentStatus.allCases.map(\.rollUpRank).min())
        #expect(AgentStatus.blocked.attentionRank == AgentStatus.allCases.map(\.attentionRank).min())
        #expect(AgentStatus.idle.rollUpRank == AgentStatus.allCases.map(\.rollUpRank).max())
    }

    // MARK: - which session wins

    // every ordered pair of statuses in a two-session workspace: the lower-ranked one wins, whichever slot
    // it sits in. Covers the "priority across all pairs" the spec asks for in one sweep.
    @Test func rollUpIndicatorPicksTheLowerRankedStatusForEveryPair() {
        for first in AgentStatus.allCases {
            for second in AgentStatus.allCases {
                let workspace = Workspace(name: "pair", sessions: [session(AgentIndicator(status: first)),
                                                                   session(AgentIndicator(status: second))])
                let expected = first.rollUpRank <= second.rollUpRank ? first : second
                #expect(workspace.rollUpIndicator.status == expected,
                        "[\(first.rawValue), \(second.rawValue)] should roll up as \(expected.rawValue)")
            }
        }
    }

    // a mixed flock: the worst state wins from ANY position — `blocked` sits LAST here, so a "first non-idle
    // session" shortcut reports `active` and fails.
    @Test func rollUpIndicatorFindsTheWorstStatusAnywhereInTheWorkspace() {
        let workspace = Workspace(name: "flock", sessions: [
            session(AgentIndicator(status: .idle)),
            session(AgentIndicator(status: .active)),
            session(AgentIndicator(status: .completed)),
            session(AgentIndicator(status: .blocked)),
        ])
        #expect(workspace.rollUpIndicator.status == .blocked)
    }

    // the case that separates the two ranks inside a real workspace: a finished run alongside one still
    // working rolls up as `completed`. Under `attentionRank` this workspace would report `active`.
    @Test func rollUpIndicatorPrefersCompletedOverActive() {
        let workspace = Workspace(name: "flock", sessions: [
            session(AgentIndicator(status: .active)),
            session(AgentIndicator(status: .completed)),
            session(AgentIndicator(status: .active)),
        ])
        #expect(workspace.rollUpIndicator.status == .completed)
    }

    // TIE-BREAK: two sessions in the SAME winning state carrying DIFFERENT decorations — one of them has to
    // supply the glyph. Ties go to the FIRST session in `sessions` order: sidebar order, so the winner is the
    // one the user would point at, and the walk stays stable instead of re-sorting equal ranks (the same
    // "just walk `sessions`" shape as `unseenCount`). A tie does NOT strip the decorations — the winner's
    // indicator is carried whole, ties included.
    @Test func rollUpIndicatorBreaksATieOnTheFirstSessionInOrder() {
        let first = AgentIndicator(status: .blocked, color: "#ff0000", shape: .star)
        let second = AgentIndicator(status: .blocked, blink: true, color: "#0000ff", shape: .square)
        #expect(Workspace(name: "flock", sessions: [session(first), session(second)]).rollUpIndicator == first)
        // reversed: the other one wins, proving the result tracks POSITION and isn't just a constant
        #expect(Workspace(name: "flock", sessions: [session(second), session(first)]).rollUpIndicator == second)
    }

    // MARK: - what the winner carries

    // the winner's indicator rides up WHOLE — its `color`/`shape`/`blink` are the agent's deliberate per-call
    // signals and belong on the parent row too — with `statusPane` the single documented exception. The
    // equality against a pane-nulled copy of the winner is the load-bearing assertion: it fails on ANY
    // dropped field, not just the ones spelled out below.
    @Test func rollUpIndicatorCarriesTheWinningIndicatorWholeExceptStatusPane() {
        let winner = AgentIndicator(status: .blocked, blink: true, autoReset: true, color: "#ff0000",
                                    shape: .star, statusPane: .right)
        let loser = AgentIndicator(status: .active, color: "#00ff00", shape: .square, statusPane: .scratch)
        let workspace = Workspace(name: "flock", sessions: [session(loser), session(winner)])

        var expected = winner
        expected.statusPane = nil
        #expect(workspace.rollUpIndicator == expected)

        #expect(workspace.rollUpIndicator.status == .blocked)
        #expect(workspace.rollUpIndicator.color == "#ff0000")
        #expect(workspace.rollUpIndicator.shape == .star)
        #expect(workspace.rollUpIndicator.blink)
        // none of the LOSER's decorations may leak into the rolled-up glyph
        #expect(workspace.rollUpIndicator.color != "#00ff00")
        #expect(workspace.rollUpIndicator.shape != .square)
    }

    // the pane is dropped whatever it was, and the tooltip is WHY: a pane is meaningless at workspace level,
    // so a carried-over `.right`/`.scratch` tag would make the parent row's tooltip claim "(split pane)"
    // about a WORKSPACE.
    @Test func rollUpIndicatorDropsEveryStatusPaneValue() {
        for pane in StatusPane.allCases {
            let workspace = Workspace(name: "flock",
                                      sessions: [session(AgentIndicator(status: .completed, statusPane: pane))])
            #expect(workspace.rollUpIndicator.statusPane == nil,
                    "a \(pane.rawValue)-tagged winner must roll up pane-less")
            #expect(workspace.rollUpIndicator.status == .completed)
            #expect(workspace.rollUpIndicator.tooltipText == "Agent status: Completed")
        }
    }

    // MARK: - nothing to report

    // no sessions and all-idle sessions both roll up to a PLAIN idle indicator, which renders no glyph and
    // collapses the row's status slot to zero width.
    @Test func rollUpIndicatorIsPlainIdleForAnEmptyOrAllIdleWorkspace() {
        #expect(Workspace(name: "empty", sessions: []).rollUpIndicator == AgentIndicator())

        let quiet = Workspace(name: "quiet", sessions: [session(AgentIndicator()), session(AgentIndicator())])
        #expect(quiet.rollUpIndicator == AgentIndicator())
        #expect(quiet.rollUpIndicator.status == .idle)
        #expect(quiet.rollUpIndicator.tooltipText == nil) // no glyph, nothing to hover
    }

    // a decoration left on an IDLE session must not resurrect a glyph on the parent: idle is idle, whatever
    // color, shape or blink rode along with it. (Only the status and the dropped pane are asserted — the
    // contract says "all-idle → idle", it does not promise the decorations are scrubbed.)
    @Test func rollUpIndicatorStaysIdleWhenIdleSessionsCarryDecorations() {
        let workspace = Workspace(name: "quiet", sessions: [
            session(AgentIndicator(status: .idle, blink: true, color: "#ff0000", shape: .star, statusPane: .right)),
        ])
        #expect(workspace.rollUpIndicator.status == .idle)
        #expect(workspace.rollUpIndicator.statusPane == nil)
        #expect(workspace.rollUpIndicator.tooltipText == nil)
    }

    // MARK: - through a real store

    // the read the sidebar actually performs: off a store-built workspace, over the LIVE session objects.
    // `Workspace` is a value type holding session REFERENCES, so a status set after the workspace value was
    // handed out still has to roll up.
    @Test func rollUpIndicatorReadsLiveSessionStateThroughTheStore() throws {
        let store = makeStore()
        let created = store.addWorkspace(name: "flock")
        let quiet = try #require(store.addSession(toWorkspace: created.id, cwd: "/tmp"))
        let noisy = try #require(store.addSession(toWorkspace: created.id, cwd: "/tmp"))

        func rollUp() -> AgentIndicator? {
            store.workspaces.first { $0.id == created.id }?.rollUpIndicator
        }
        #expect(rollUp()?.status == .idle, "a fresh workspace's sessions are idle")

        store.setAgentIndicator(AgentIndicator(status: .active), forSession: quiet.id)
        #expect(rollUp()?.status == .active)

        store.setAgentIndicator(AgentIndicator(status: .blocked, blink: true), forSession: noisy.id)
        #expect(rollUp() == AgentIndicator(status: .blocked, blink: true))

        // clearing the worst child falls back to the next-worst, not to idle
        store.setAgentIndicator(AgentIndicator(), forSession: noisy.id)
        #expect(rollUp()?.status == .active)
    }

    /// A session carrying `indicator`, in the plain-`Session` style `WorkspaceTests` uses for the
    /// `unseenCount` roll-up.
    private func session(_ indicator: AgentIndicator) -> Session {
        let session = Session(initialCwd: "/tmp")
        session.agentIndicator = indicator
        return session
    }
}
