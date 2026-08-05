import Foundation
import Testing
@testable import rookCore

/// Closing the ACTIVE session returns to the most-recently-active SURVIVING session, scoped to the closing
/// session's workspace ∩ the VISIBLE set — the flagged list in `.flagged` mode, the marked workspaces'
/// sessions while the focus filter applies — widening through everything visible and then the whole tree as
/// each level is exhausted, with a positional walk as the last fallback (GitHub Discussion #147).
/// See `closeReselectionTarget(after:)`.
@MainActor
struct AppStoreCloseReselectionTests {
    @Test func closeActiveSessionInsertedAfterCurrentReturnsToTheSessionItCameFrom() throws {
        // discussion example 1: from `1 2 3` on `1`, a new session inserted after the current one
        // (`1 4 2 3`) and closed lands back on `1` — not on the positional neighbor `2`.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let one = try #require(store.addSession(toWorkspace: ws.id, cwd: "/1"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/2"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/3"))
        store.selectSession(one.id)
        let four = try #require(store.addSession(toWorkspace: ws.id, cwd: "/4", at: 1))
        #expect(store.selectedSessionID == four.id)

        store.closeSession(four.id)
        #expect(store.selectedSessionID == one.id) // not `2`, which shifted into the removed slot
    }

    @Test func closeActiveSessionAppendedAtTheEndReturnsToTheSessionItCameFrom() throws {
        // discussion example 2: from `1 2 3` on `1`, a new session appended (`1 2 3 4`) and closed
        // lands back on `1` — not on the positional previous `3`.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let one = try #require(store.addSession(toWorkspace: ws.id, cwd: "/1"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/2"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/3"))
        store.selectSession(one.id)
        let four = try #require(store.addSession(toWorkspace: ws.id, cwd: "/4"))

        store.closeSession(four.id)
        #expect(store.selectedSessionID == one.id) // not `3`, the positional previous
    }

    @Test func closeActiveSessionPrefersTheRecentSurvivorOverThePositionalNeighbor() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        let fourth = try #require(store.addSession(toWorkspace: ws.id, cwd: "/d"))
        store.selectSession(first.id)
        store.selectSession(second.id)
        store.selectSession(fourth.id)

        store.closeSession(fourth.id)
        #expect(store.selectedSessionID == second.id) // the MRU survivor, though `c` is the neighbor
    }

    @Test func closeActiveSessionIgnoresAMoreRecentSessionInAnotherWorkspace() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let inWork = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        let elsewhere = try #require(store.addSession(toWorkspace: personal.id, cwd: "/x"))
        store.selectSession(inWork.id)
        store.selectSession(elsewhere.id) // more recent than `inWork`, but in another workspace
        store.selectSession(closing.id)

        store.closeSession(closing.id)
        #expect(store.selectedSessionID == inWork.id) // stays put, though `elsewhere` is more recent
        #expect(!store.focusEnabled) // the close must not introduce a focus filter
        #expect(store.focusedWorkspaceIDs.isEmpty) // nor mark anything
    }

    @Test func closeActiveSessionEmptyingItsWorkspacePicksTheRecentSurvivorElsewhere() throws {
        // the workspace scope has nothing left to hold on to once the close empties the workspace, so the
        // MRU widens to the whole TREE rather than jumping positionally into the first workspace.
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let scratch = store.addWorkspace(name: "scratch")
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let cameFrom = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        let onlyInScratch = try #require(store.addSession(toWorkspace: scratch.id, cwd: "/x"))
        store.selectSession(cameFrom.id)
        store.selectSession(onlyInScratch.id)

        store.closeSession(onlyInScratch.id)
        #expect(store.workspaces[1].sessions.isEmpty)
        #expect(store.selectedSessionID == cameFrom.id) // not `work`'s positionally-first session `/a`
    }

    @Test func closeActiveSessionWithAFocusFilterStaysInsideTheFocusedWorkspace() throws {
        let store = makeStore()
        let personal = store.addWorkspace(name: "personal")
        let work = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: personal.id, cwd: "/x"))
        let first = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        let closing = try #require(store.addSession(toWorkspace: work.id, cwd: "/c"))
        store.selectSession(first.id)
        store.selectSession(closing.id)
        store.setFocusedWorkspace(work.id)

        store.closeSession(closing.id)
        #expect(store.selectedSessionID == first.id) // the MRU survivor, not the positional neighbor `/b`
        #expect(store.soleFocusedWorkspaceID == work.id) // the filter survives the close, still applied
    }

    @Test func closeTheFocusedWorkspacesLastSessionPicksTheRecentSurvivorElsewhere() throws {
        // the focus filter must NOT scope the widened MRU: under focus, `navigableSessions` collapses to the
        // marked set, so scoping by it would widen into an EMPTY set once the close empties the only marked
        // workspace and fall through to a positional jump into the FIRST workspace — the very disorientation
        // this feature removes. `disableFocusIfSelectionOutsideSet` lifts the now-meaningless filter instead,
        // and lifts ONLY the flag: the marked set survives, so one toggle brings the working set back.
        let store = makeStore()
        let personal = store.addWorkspace(name: "personal")
        let work = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: personal.id, cwd: "/first"))
        let cameFrom = try #require(store.addSession(toWorkspace: personal.id, cwd: "/mru"))
        let onlyInWork = try #require(store.addSession(toWorkspace: work.id, cwd: "/only"))
        store.selectSession(cameFrom.id)
        store.selectSession(onlyInWork.id)
        store.setFocusedWorkspace(work.id)

        store.closeSession(onlyInWork.id)
        #expect(store.workspaces[1].sessions.isEmpty)
        #expect(store.selectedSessionID == cameFrom.id) // not `/first`, the positional first-workspace jump
        #expect(!store.focusEnabled) // the filter is lifted to reveal the pick
        #expect(store.focusedWorkspaceIDs == [work.id]) // but the MARK survives — only the flag dropped
    }

    @Test func closeUnderAFocusFilterStaysInsideTheMarkedSet() throws {
        // the state this used to pin — the marked set sitting on a workspace the ACTIVE session doesn't
        // belong to — is now unreachable: `setFocusedWorkspace` moves the selection into the visible set
        // (`reselectIfSelectionHidden`). So the close is scoped by a filter the active session is INSIDE,
        // and `elsewhere` — more recent than `survivor` — must not win despite being the MRU overall.
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let survivor = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: work.id, cwd: "/c"))
        let elsewhere = try #require(store.addSession(toWorkspace: personal.id, cwd: "/x"))
        store.selectSession(survivor.id)
        store.selectSession(elsewhere.id)
        store.selectSession(closing.id)
        store.setFocusedWorkspace(work.id)
        #expect(store.selectedSessionID == closing.id) // already in-set, so the narrowing moved nothing

        store.closeSession(closing.id)
        #expect(store.selectedSessionID == survivor.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled) // the filter survives the close
    }

    @Test func closeInAMarkedWorkspaceCrossesToTheOtherMemberNotAnUnmarkedSurvivor() throws {
        // the widening's SECOND level: the closing workspace is emptied, so the scope grows to everything
        // VISIBLE rather than to the whole tree. `unmarked` is deliberately more recent than `otherMember`,
        // so an unscoped MRU would take it and land the selection on a row the filtered sidebar cannot draw.
        let store = makeStore()
        let first = store.addWorkspace(name: "first")
        let second = store.addWorkspace(name: "second")
        let outside = store.addWorkspace(name: "outside")
        let closing = try #require(store.addSession(toWorkspace: first.id, cwd: "/only"))
        let otherMember = try #require(store.addSession(toWorkspace: second.id, cwd: "/member", select: false))
        let unmarked = try #require(store.addSession(toWorkspace: outside.id, cwd: "/stray", select: false))
        store.selectSession(otherMember.id)
        store.selectSession(unmarked.id)
        store.selectSession(closing.id)
        store.setFocusMembership(first.id, member: true)
        store.setFocusMembership(second.id, member: true)
        store.setFocusEnabled(true)

        store.closeSession(closing.id)
        #expect(store.workspaces[0].sessions.isEmpty)
        #expect(store.selectedSessionID == otherMember.id)
        #expect(store.focusedWorkspaceIDs == [first.id, second.id] && store.focusEnabled)
    }

    @Test func closeUnderAFocusFilterWithNoRecencyKeepsThePositionalPickInsideTheSet() throws {
        // the positional fallback is scoped by the FOCUS filter too, not just by flagged mode: a cold
        // restore leaves nothing in the recency stack, and the unmarked workspace sits BETWEEN the emptied
        // one and the other member, so the whole-tree walk and the in-scope walk disagree.
        let store = makeStore()
        let wsClosing = UUID(), wsUnmarked = UUID(), wsOtherMember = UUID()
        let closing = UUID(), outside = UUID(), inSet = UUID()
        store.restore(from: Snapshot(selectedSessionID: closing, workspaces: [
            WorkspaceSnapshot(id: wsClosing, name: "closing", sessions: [
                SessionSnapshot(id: closing, customName: nil, cwd: "/closing"),
            ]),
            WorkspaceSnapshot(id: wsUnmarked, name: "unmarked", sessions: [
                SessionSnapshot(id: outside, customName: nil, cwd: "/outside"),
            ]),
            WorkspaceSnapshot(id: wsOtherMember, name: "member", sessions: [
                SessionSnapshot(id: inSet, customName: nil, cwd: "/inset"),
            ]),
        ], focusedWorkspaceIDs: [wsClosing, wsOtherMember], focusEnabled: true))
        #expect(store.sessionRecency.items == [closing]) // only the restored selection

        store.closeSession(closing)
        #expect(store.selectedSessionID == inSet)
        #expect(store.focusedWorkspaceIDs == [wsClosing, wsOtherMember] && store.focusEnabled)
    }

    @Test func closeActiveSessionLandingInAnotherMARKEDWorkspaceKeepsTheFilterApplied() throws {
        // the set generalizes the drop rule the two tests above pin: the filter is lifted only when the pick
        // lands OUTSIDE it. A widened MRU that lands in a SECOND member is on screen already, so there is
        // nothing to reveal and the filter must stay applied — under a single mark this same close dropped it.
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let cameFrom = try #require(store.addSession(toWorkspace: personal.id, cwd: "/mru"))
        let onlyInWork = try #require(store.addSession(toWorkspace: work.id, cwd: "/only"))
        store.selectSession(cameFrom.id)
        store.selectSession(onlyInWork.id)
        store.setFocusedWorkspace(work.id)
        store.setFocusMembership(personal.id, member: true) // the marked set is {work, personal}

        store.closeSession(onlyInWork.id)
        #expect(store.workspaces[0].sessions.isEmpty)
        #expect(store.selectedSessionID == cameFrom.id) // the widened MRU pick, in the other member
        #expect(store.focusEnabled) // in-set, so nothing needed revealing
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id]) // and the emptied member is still marked
    }

    @Test func closeActiveSessionInFlaggedModeStaysWithinTheFlaggedSet() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let flagged = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let unflagged = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        store.setFlag(true, forSession: flagged.id)
        store.setFlag(true, forSession: closing.id)
        store.sidebarMode = .flagged
        store.selectSession(flagged.id)
        store.selectSession(unflagged.id) // more recent, but outside the flagged view
        store.selectSession(closing.id)

        store.closeSession(closing.id)
        #expect(store.selectedSessionID == flagged.id) // not `unflagged`, though it is the more recent
    }

    @Test func closeActiveSessionInFlaggedModeCrossesWorkspacesRatherThanLeavingTheFlaggedSet() throws {
        // `flaggedSessions` is cross-workspace by definition, so when the close leaves the closing
        // session's workspace with no flagged survivor, the pick follows the FILTER out of the workspace
        // instead of falling back to an unflagged sibling the sidebar isn't even rendering.
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let unflagged = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        let flaggedElsewhere = try #require(store.addSession(toWorkspace: personal.id, cwd: "/x"))
        store.setFlag(true, forSession: closing.id)
        store.setFlag(true, forSession: flaggedElsewhere.id)
        store.sidebarMode = .flagged
        store.selectSession(flaggedElsewhere.id)
        store.selectSession(unflagged.id) // the most recent overall, but outside the flagged view
        store.selectSession(closing.id)

        store.closeSession(closing.id)
        #expect(store.selectedSessionID == flaggedElsewhere.id) // the only flagged survivor
        #expect(store.flaggedSessions.map(\.id).contains(try #require(store.selectedSessionID)))
    }

    @Test func closeActiveSessionInFlaggedModeWithAnEmptyScopedRecencyStaysWithinTheFlaggedSet() throws {
        // a cold restore in flagged mode: once the closing session is pruned the scoped recency is empty,
        // so the pick falls back — but the positional neighbor is unflagged and the flagged sidebar has no
        // row for it, so the fallback must stay inside the filter.
        let store = makeStore()
        let wsID = UUID()
        let ids = [UUID(), UUID(), UUID()]
        let sessions = [SessionSnapshot(id: ids[0], customName: nil, cwd: "/a", flagged: true),
                        SessionSnapshot(id: ids[1], customName: nil, cwd: "/b", flagged: true),
                        SessionSnapshot(id: ids[2], customName: nil, cwd: "/c")]
        store.restore(from: Snapshot(selectedSessionID: ids[1],
                                     workspaces: [WorkspaceSnapshot(id: wsID, name: "work", sessions: sessions)],
                                     sidebarMode: .flagged))
        #expect(store.sessionRecency.items == [ids[1]]) // only the restored selection

        store.closeSession(ids[1])
        #expect(store.selectedSessionID == ids[0]) // the flagged survivor, not the unflagged `ids[2]`
        #expect(store.flaggedSessions.map(\.id).contains(try #require(store.selectedSessionID)))
    }

    @Test func closeActiveSessionInFlaggedModeWithAnEmptyScopedRecencyPicksTheNEARESTFlaggedSurvivor() throws {
        // the filtered fallback is positional WITHIN the flagged set, not "the first flagged row": closing a
        // session in the middle of the flagged list must land on the flagged row that shifted into its slot,
        // the same locality the unfiltered positional fallback has.
        let store = makeStore()
        let wsID = UUID()
        let ids = [UUID(), UUID(), UUID()]
        let sessions = ids.map { SessionSnapshot(id: $0, customName: nil, cwd: "/\($0)", flagged: true) }
        store.restore(from: Snapshot(selectedSessionID: ids[1],
                                     workspaces: [WorkspaceSnapshot(id: wsID, name: "work", sessions: sessions)],
                                     sidebarMode: .flagged))
        #expect(store.sessionRecency.items == [ids[1]]) // only the restored selection

        store.closeSession(ids[1])
        #expect(store.selectedSessionID == ids[2]) // the neighbor that shifted up, not the top of the list
    }

    @Test func closeTheWorkspacesLastFlaggedSessionWithAnEmptyRecencyPicksTheADJACENTFlaggedRow() throws {
        // the scope widens across workspaces once the close leaves the closing workspace with no flagged
        // survivor, and the flagged sidebar renders that widened set as one flat list — so the fallback must
        // stay positional THERE too: the flagged row adjacent to the closed one, not the top of the list.
        let store = makeStore()
        let first = UUID(), last = UUID()
        let ids = (0..<4).map { _ in UUID() }
        let flaggedElsewhere = [SessionSnapshot(id: ids[0], customName: nil, cwd: "/a", flagged: true),
                                SessionSnapshot(id: ids[1], customName: nil, cwd: "/b", flagged: true)]
        let closing = [SessionSnapshot(id: ids[2], customName: nil, cwd: "/c"),
                       SessionSnapshot(id: ids[3], customName: nil, cwd: "/d", flagged: true)]
        store.restore(from: Snapshot(selectedSessionID: ids[3],
                                     workspaces: [WorkspaceSnapshot(id: first, name: "work", sessions: flaggedElsewhere),
                                                  WorkspaceSnapshot(id: last, name: "personal", sessions: closing)],
                                     sidebarMode: .flagged))
        #expect(store.sessionRecency.items == [ids[3]]) // only the restored selection

        store.closeSession(ids[3])
        #expect(store.selectedSessionID == ids[1]) // the flagged row before it, not the first flagged row
    }

    @Test func closeTheLastFlaggedSessionWidensToTheWholeTree() throws {
        // the visible scope is empty once the only flagged session is the one closing, so the widening
        // reaches its last level, the whole TREE — the flagged sidebar renders no rows at all in that state,
        // so there is no in-filter row left to keep the pick inside, and selecting nothing would leave no
        // terminal. The MRU survivor is what proves it widened rather than falling to the positional pick:
        // `/c` is the neighbor that shifted into the removed slot.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let recentSurvivor = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        store.setFlag(true, forSession: closing.id)
        store.sidebarMode = .flagged
        store.selectSession(recentSurvivor.id)
        store.selectSession(closing.id)

        store.closeSession(closing.id)
        #expect(store.flaggedSessions.isEmpty)
        #expect(store.selectedSessionID == recentSurvivor.id)
    }

    @Test func closeActiveSessionWithAnEmptyScopedRecencyFallsBackToThePositionalTarget() throws {
        // a cold restore: nothing has been activated, so once the closing session is pruned the scoped
        // recency is empty and the pick is exactly today's positional neighbor.
        let store = makeStore()
        let wsID = UUID()
        let ids = [UUID(), UUID(), UUID()]
        let sessions = ids.enumerated().map { SessionSnapshot(id: $1, customName: nil, cwd: "/\($0)") }
        store.restore(from: Snapshot(selectedSessionID: ids[1],
                                     workspaces: [WorkspaceSnapshot(id: wsID, name: "work", sessions: sessions)]))
        #expect(store.sessionRecency.items == [ids[1]]) // only the restored selection

        store.closeSession(ids[1])
        #expect(store.selectedSessionID == ids[2]) // the session that shifted into the removed slot
    }

    @Test func softCloseActiveSessionPicksTheRecentSurvivorLikeTheHardClose() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/d"))
        store.selectSession(first.id)
        store.selectSession(closing.id)

        #expect(store.softCloseSession(closing.id, grace: 60))
        #expect(store.selectedSessionID == first.id) // the MRU survivor, not the positional neighbor `/c`
    }

    @Test func softCloseActiveSessionWithAnEmptyScopedRecencyFallsBackToThePositionalTarget() throws {
        // the single soft close owns its own call into the helper, so pin its fallback leg too: a cold
        // restore leaves nothing in the recency stack but the session being closed.
        let store = makeStore()
        let wsID = UUID()
        let ids = [UUID(), UUID(), UUID()]
        let sessions = ids.enumerated().map { SessionSnapshot(id: $1, customName: nil, cwd: "/\($0)") }
        store.restore(from: Snapshot(selectedSessionID: ids[1],
                                     workspaces: [WorkspaceSnapshot(id: wsID, name: "work", sessions: sessions)]))

        #expect(store.softCloseSession(ids[1], grace: 60))
        #expect(store.selectedSessionID == ids[2]) // the session that shifted into the removed slot
    }

    @Test func softCloseSessionsNeverPicksAMemberOfTheClosingGroup() throws {
        // the soft-close paths deliberately leave the closing sessions in `sessionRecency` (undo needs
        // them back), so the MRU pick must be kept off them by the TREE-derived scope alone.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let oldest = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let survivor = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let alsoClosing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/d"))
        store.selectSession(oldest.id)
        store.selectSession(survivor.id)
        store.selectSession(alsoClosing.id)
        store.selectSession(closing.id)

        #expect(store.softCloseSessions([alsoClosing.id, closing.id], grace: 60))
        #expect(store.selectedSessionID == survivor.id) // the most recent survivor OUTSIDE the group
        // both closed sessions are more recent than `survivor` and still in the stack, yet unpickable
        #expect(store.sessionRecency.items.contains(closing.id))
        #expect(store.sessionRecency.items.contains(alsoClosing.id))
    }

    @Test func undoOfASoftCloseStillRestoresThePreviouslySelectedSession() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let other = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        store.selectSession(other.id)
        store.selectSession(closing.id)

        #expect(store.softCloseSession(closing.id, grace: 60))
        #expect(store.selectedSessionID == other.id)

        let summary = try #require(store.pendingCloseSummary)
        #expect(store.undoPendingClose(summary.id))
        #expect(store.session(withID: closing.id) === closing)
        #expect(store.selectedSessionID == closing.id) // undo reselects what was closed
    }

    @Test func graceExpiryAfterASoftCloseLeavesTheSelectionAlone() async throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let survivor = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let surface = SpySurface()
        closing.surface = surface
        store.selectSession(survivor.id)
        store.selectSession(closing.id)

        #expect(store.softCloseSession(closing.id, grace: 0.01))
        #expect(store.selectedSessionID == survivor.id)
        // poll the teardown rather than a flat sleep: the grace timer can land late under parallel load
        for _ in 0..<200 {
            if surface.teardownCount == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(surface.teardownCount == 1)
        #expect(store.selectedSessionID == survivor.id) // finalization must not re-run reselection
        #expect(!store.sessionRecency.items.contains(closing.id)) // finalize prunes it now
    }

    @Test func closeActiveSessionNeverClearsTheSelectionWhileSessionsSurvive() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        _ = try #require(store.addSession(toWorkspace: personal.id, cwd: "/x"))

        for remaining in stride(from: 3, through: 2, by: -1) {
            let active = try #require(store.selectedSessionID)
            store.closeSession(active)
            #expect(store.selectedSessionID != nil, "\(remaining - 1) sessions survive, selection must not go nil")
        }
        let last = try #require(store.selectedSessionID)
        store.closeSession(last)
        #expect(store.selectedSessionID == nil) // the tree is empty now
    }
}
