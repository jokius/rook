import Foundation
import Testing
@testable import rookCore

@MainActor
struct AppStoreNavigationTests {
    @Test func navigateSessionStaysWithinFocusedWorkspace() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        _ = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        store.selectSession(a.id)
        store.setFocusedWorkspace(work.id)
        store.navigateSession(.next) // nav is scoped to the marked set (only a); wrap cycles to itself
        #expect(store.selectedSessionID == a.id) // stays on a — the out-of-set session is never revealed
        #expect(store.soleFocusedWorkspaceID == work.id) // nav never crosses the filter, so it stands
    }

    /// Builds a two-workspace tree (work: a, b; personal: c, d) so flattened order is [a, b, c, d].
    static func makeNavTree() -> (store: AppStore, ids: [UUID]) {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: work.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: personal.id, cwd: "/c")!
        let d = store.addSession(toWorkspace: personal.id, cwd: "/d")!
        return (store, [a.id, b.id, c.id, d.id])
    }

    /// Builds a FIVE-workspace tree — w1={a}, w2={b,c}, w3={d}, w4={e,f}, w5={g} — so the 2-of-5 marked set
    /// {w2, w4} leaves an unmarked workspace in the MIDDLE (w3) and one at EACH END (w1, w5). Flattened tree
    /// order is [a…g]; the marked union is [b, c, e, f], whose first and last both differ from the tree's,
    /// so a filtered `.first`/`.last`/wrap can't accidentally agree with the unfiltered one.
    static func makeSpacedNavTree() -> (store: AppStore, sessions: [UUID], workspaces: [UUID]) {
        let store = makeStore()
        var workspaces: [UUID] = []
        var sessions: [UUID] = []
        for (name, count) in zip(["w1", "w2", "w3", "w4", "w5"], [1, 2, 1, 2, 1]) {
            let workspace = store.addWorkspace(name: name)
            workspaces.append(workspace.id)
            for i in 0..<count { sessions.append(store.addSession(toWorkspace: workspace.id, cwd: "/\(name)-\(i)")!.id) }
        }
        return (store, sessions, workspaces)
    }

    @Test func navigateNextStepsForwardCrossingWorkspaces() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(ids[0])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[1])
        store.navigateSession(.next) // crosses from work into personal
        #expect(store.selectedSessionID == ids[2])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[3])
    }

    @Test func navigatePreviousStepsBackwardCrossingWorkspaces() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(ids[3])
        store.navigateSession(.previous)
        #expect(store.selectedSessionID == ids[2])
        store.navigateSession(.previous) // crosses from personal into work
        #expect(store.selectedSessionID == ids[1])
        store.navigateSession(.previous)
        #expect(store.selectedSessionID == ids[0])
    }

    @Test func navigateNextAtLastWrapsToFirst() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(ids.last!)
        store.navigateSession(.next) // at the end: wraps around to the first
        #expect(store.selectedSessionID == ids.first!)
    }

    @Test func navigatePreviousAtFirstWrapsToLast() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(ids.first!)
        store.navigateSession(.previous) // at the start: wraps around to the last
        #expect(store.selectedSessionID == ids.last!)
    }

    @Test func navigateFirstAndLastJumpToEnds() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(ids[1])
        store.navigateSession(.last)
        #expect(store.selectedSessionID == ids.last!)
        store.navigateSession(.first)
        #expect(store.selectedSessionID == ids.first!)
    }

    @Test func navigateWithNoSelectionLandsOnFirst() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(nil)
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids.first!)
        store.selectSession(nil)
        store.navigateSession(.previous)
        #expect(store.selectedSessionID == ids.first!)
    }

    @Test func navigateFirstAndLastWithNoSelectionLandOnEnds() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(nil)
        store.navigateSession(.last)
        #expect(store.selectedSessionID == ids.last!) // .last ignores the (absent) selection
        store.selectSession(nil)
        store.navigateSession(.first)
        #expect(store.selectedSessionID == ids.first!) // .first ignores the (absent) selection
    }

    @Test func navigateSingleSessionStaysSelected() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let only = store.addSession(toWorkspace: ws.id, cwd: "/only")!
        store.selectSession(only.id)
        for direction in [SessionNavigation.next, .previous, .first, .last] {
            store.navigateSession(direction)
            #expect(store.selectedSessionID == only.id)
        }
    }

    @Test func navigateEmptyTreeIsNoOp() {
        let store = makeStore()
        store.addWorkspace(name: "work") // no sessions
        store.navigateSession(.next)
        #expect(store.selectedSessionID == nil)
        store.navigateSession(.first)
        #expect(store.selectedSessionID == nil)
    }

    @Test func navigateRoutesThroughSelectSession() {
        let (store, ids) = Self.makeNavTree()
        store.session(withID: ids[1])?.unseenCount = 5
        store.selectSession(ids[0])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[1])
        #expect(store.session(withID: ids[1])?.unseenCount == 0) // selectSession cleared the badge
        // the navigation pushed a NEW recency entry on top of the prior selection (most-recent first).
        #expect(Array(store.sessionRecency.items.prefix(2)) == [ids[1], ids[0]])
    }

    @Test func sessionNavigationWireMapping() {
        #expect(SessionNavigation(wire: "next") == .next)
        #expect(SessionNavigation(wire: "prev") == .previous)
        #expect(SessionNavigation(wire: "previous") == .previous)
        #expect(SessionNavigation(wire: "first") == .first)
        #expect(SessionNavigation(wire: "last") == .last)
        #expect(SessionNavigation(wire: "next-attention") == .nextAttention)
        #expect(SessionNavigation(wire: "prev-attention") == .previousAttention)
        #expect(SessionNavigation(wire: "previous-attention") == .previousAttention)
        #expect(SessionNavigation(wire: "sideways") == nil)
    }

    @Test func navigateAttentionStepsThroughAttentionSessionsOnly() {
        let (store, ids) = Self.makeNavTree() // a, b, c, d
        store.session(withID: ids[1])?.agentIndicator = AgentIndicator(status: .blocked)   // b
        store.session(withID: ids[3])?.agentIndicator = AgentIndicator(status: .completed) // d
        store.selectSession(ids[0]) // a (idle)
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[1]) // skips to blocked b
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[3]) // skips idle c, lands on completed d
    }

    @Test func navigateAttentionWrapsAround() {
        let (store, ids) = Self.makeNavTree()
        store.session(withID: ids[1])?.agentIndicator = AgentIndicator(status: .blocked)   // b
        store.session(withID: ids[3])?.agentIndicator = AgentIndicator(status: .completed) // d
        store.selectSession(ids[3]) // d (last attention)
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[1]) // wraps forward to b
        store.navigateSession(.previousAttention)
        #expect(store.selectedSessionID == ids[3]) // wraps backward to d
    }

    @Test func navigateAttentionSkipsActiveAndIdle() {
        let (store, ids) = Self.makeNavTree()
        store.session(withID: ids[1])?.agentIndicator = AgentIndicator(status: .active)  // b active - excluded
        store.session(withID: ids[2])?.agentIndicator = AgentIndicator(status: .blocked) // c blocked - included
        store.selectSession(ids[0])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[2]) // skips active b, lands on blocked c
    }

    @Test func navigateAttentionWithSingleAttentionSessionStaysPut() {
        let (store, ids) = Self.makeNavTree()
        store.session(withID: ids[2])?.agentIndicator = AgentIndicator(status: .completed) // c, the only one
        store.selectSession(ids[2])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[2]) // no other attention session -> no-op
        store.navigateSession(.previousAttention)
        #expect(store.selectedSessionID == ids[2])
    }

    @Test func navigateAttentionWithNoAttentionSessionsIsNoOp() {
        let (store, ids) = Self.makeNavTree()
        store.selectSession(ids[0])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[0])
    }

    @Test func navigateAttentionWithNoSelectionLandsOnAnAttentionEnd() {
        let (store, ids) = Self.makeNavTree()
        store.session(withID: ids[1])?.agentIndicator = AgentIndicator(status: .blocked)   // b
        store.session(withID: ids[3])?.agentIndicator = AgentIndicator(status: .completed) // d
        store.selectSession(nil)
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[1]) // forward from before-first -> first attention
        store.selectSession(nil)
        store.navigateSession(.previousAttention)
        #expect(store.selectedSessionID == ids[3]) // backward from after-last -> last attention
    }

    // MARK: - navigation scoping (filtered set)

    @Test func navigableSessionsReflectsFlaggedFocusAndUnfocused() {
        let (store, ids) = Self.makeNavTree() // work={a,b}, personal={c,d}
        #expect(store.navigableSessions.map(\.id) == ids) // filter off in tree mode -> every session
        let work = store.workspace(forSession: ids[0])!
        store.setFocusedWorkspace(work.id)
        #expect(store.navigableSessions.map(\.id) == [ids[0], ids[1]]) // marked AND applied -> that member only
        store.setFocusEnabled(false)
        #expect(store.navigableSessions.map(\.id) == ids) // the mark stands, but a lifted filter scopes nothing
        store.setFocusEnabled(true)
        #expect(store.navigableSessions.map(\.id) == [ids[0], ids[1]]) // coming back re-scopes to the SAME set
        store.clearFocus()
        store.setFlag(true, forSession: ids[1])
        store.setFlag(true, forSession: ids[2])
        store.setSidebarMode(.flagged)
        #expect(store.navigableSessions.map(\.id) == [ids[1], ids[2]]) // flagged mode -> the flagged set
    }

    @Test func navigableSessionsUnionsEveryMarkedWorkspaceInTreeOrder() {
        let (store, ids, ws) = Self.makeSpacedNavTree() // w1={a}, w2={b,c}, w3={d}, w4={e,f}, w5={g}
        store.setFocusedWorkspace(ws[1])
        store.setFocusMembership(ws[3], member: true) // {w2, w4}: w3 sits UNMARKED between them
        // the union is every member's sessions in TREE order — w3's d is dropped from the middle, and the
        // unmarked ends (a, g) never appear, so this is neither "the first member" nor a contiguous slice.
        #expect(store.navigableSessions.map(\.id) == [ids[1], ids[2], ids[4], ids[5]])
        #expect(store.visibleWorkspaces.map(\.id) == [ws[1], ws[3]]) // and the rows the sidebar renders agree
    }

    @Test func navigateWalksEveryMarkedWorkspaceAndSkipsTheUnmarkedOnesBetweenThem() {
        let (store, ids, ws) = Self.makeSpacedNavTree() // tree order [a,b,c,d,e,f,g]; union {w2,w4} = [b,c,e,f]
        store.setFocusedWorkspace(ws[1])
        store.setFocusMembership(ws[3], member: true)
        store.selectSession(ids[1]) // b
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[2]) // b -> c, inside the first member
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[4]) // c -> e: steps over the unmarked d into the SECOND member
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[5]) // e -> f
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[1]) // f is the union's last: wraps to b, not on to the unmarked g
        store.navigateSession(.previous)
        #expect(store.selectedSessionID == ids[5]) // and back over the same wrap, never onto a
        store.navigateSession(.previous)
        #expect(store.selectedSessionID == ids[4])
        store.navigateSession(.previous)
        #expect(store.selectedSessionID == ids[2]) // e -> c: d is skipped backwards too
        store.navigateSession(.last)
        #expect(store.selectedSessionID == ids[5]) // .last is the UNION's last (f), not the tree's (g)
        store.navigateSession(.first)
        #expect(store.selectedSessionID == ids[1]) // .first is the union's first (b), not the tree's (a)
        #expect(store.focusedWorkspaceIDs == [ws[1], ws[3]]) // every target was in-set, so the filter stands
        #expect(store.focusEnabled)
    }

    @Test func navigateAttentionWalksEveryMarkedWorkspaceAndSkipsTheUnmarkedOnesBetweenThem() {
        let (store, ids, ws) = Self.makeSpacedNavTree()
        store.setFocusedWorkspace(ws[1])
        store.setFocusMembership(ws[3], member: true) // union = [b, c, e, f]
        store.session(withID: ids[2])?.agentIndicator = AgentIndicator(status: .blocked)   // c, in w2
        store.session(withID: ids[3])?.agentIndicator = AgentIndicator(status: .blocked)   // d, in the UNMARKED w3
        store.session(withID: ids[5])?.agentIndicator = AgentIndicator(status: .completed) // f, in w4
        store.session(withID: ids[6])?.agentIndicator = AgentIndicator(status: .blocked)   // g, in the UNMARKED w5
        store.selectSession(ids[1]) // b
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[2]) // the first in-set attention session
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[5]) // crosses to w4's f, never stopping on the hidden d
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[2]) // wraps within the union, never reaching the hidden g
        store.navigateSession(.previousAttention)
        #expect(store.selectedSessionID == ids[5]) // backwards wraps through the same two
        #expect(store.focusEnabled) // attention-nav is in-set too, so it never lifts the filter
    }

    @Test func navigateScopesToFocusedWorkspace() {
        let (store, ids) = Self.makeNavTree() // work={a,b}, personal={c,d}
        let work = store.workspace(forSession: ids[0])!
        store.setFocusedWorkspace(work.id)
        store.selectSession(ids[0])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[1]) // a -> b within the focused workspace
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[0]) // b is the in-set last: wraps within {a,b} to a, never crosses to c
        store.navigateSession(.last)
        #expect(store.selectedSessionID == ids[1]) // .last is the focused workspace's last, not the tree's
        store.navigateSession(.first)
        #expect(store.selectedSessionID == ids[0]) // .first is the focused workspace's first
        #expect(store.soleFocusedWorkspaceID == work.id) // never lifts the filter — every target was in-set
    }

    @Test func navigateScopesToFlaggedSet() {
        let (store, ids) = Self.makeNavTree() // a, b, c, d
        store.setFlag(true, forSession: ids[0]) // a
        store.setFlag(true, forSession: ids[2]) // c
        store.setSidebarMode(.flagged)
        store.selectSession(ids[0])
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[2]) // a -> c, skipping the unflagged b
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[0]) // c is the flagged-set last: wraps to a, the flagged-set first
        store.navigateSession(.first)
        #expect(store.selectedSessionID == ids[0]) // .first is the flagged set's first
    }

    @Test func navigateAttentionScopesToFocusedWorkspace() {
        let (store, ids) = Self.makeNavTree() // work={a,b}, personal={c,d}
        store.session(withID: ids[1])?.agentIndicator = AgentIndicator(status: .blocked)   // b (in focus)
        store.session(withID: ids[3])?.agentIndicator = AgentIndicator(status: .completed) // d (off focus)
        let work = store.workspace(forSession: ids[0])!
        store.setFocusedWorkspace(work.id)
        store.selectSession(ids[0])
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[1]) // only b is in the focused set; d is never reached
        store.navigateSession(.nextAttention)
        #expect(store.selectedSessionID == ids[1]) // b is the single in-set attention session: stays
    }

    @Test func navigateRestoresFullSetWhenFocusCleared() {
        let (store, ids) = Self.makeNavTree()
        let work = store.workspace(forSession: ids[0])!
        store.setFocusedWorkspace(work.id)
        store.selectSession(ids[1]) // b, the in-set last of {a,b}
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[0]) // scoped: wraps within {a,b} back to a, never crosses to c
        store.clearFocus() // clearing focus restores the full navigable set
        store.selectSession(ids[1]) // b again, now in the full set [a,b,c,d]
        store.navigateSession(.next)
        #expect(store.selectedSessionID == ids[2]) // now crosses into the personal workspace
    }

    // MARK: - attentionSessions

    @Test func attentionSessionsFiltersOutIdle() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = store.addSession(toWorkspace: ws.id, cwd: "/idle") // stays idle
        let active = store.addSession(toWorkspace: ws.id, cwd: "/active")!
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: active.id)
        // idle sessions are dropped; only the non-idle one is listed
        #expect(store.attentionSessions.map(\.id) == [active.id])
    }

    @Test func attentionSessionsOrderBlockedActiveCompleted() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let completed = store.addSession(toWorkspace: ws.id, cwd: "/c")!
        let active = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let blocked = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        // set in a non-rank order; the list must still sort blocked -> active -> completed
        store.setAgentIndicator(AgentIndicator(status: .completed), forSession: completed.id)
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: active.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: blocked.id)
        #expect(store.attentionSessions.map(\.id) == [blocked.id, active.id, completed.id])
    }

    @Test func attentionSessionsWithinRankOrderNewestFirstNilLast() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let oldest = store.addSession(toWorkspace: ws.id, cwd: "/old")!
        let newest = store.addSession(toWorkspace: ws.id, cwd: "/new")!
        let unstamped = store.addSession(toWorkspace: ws.id, cwd: "/none")!
        // all three are blocked (same rank), so the tie-break is statusChangedAt descending, nil last
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: oldest.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: newest.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: unstamped.id)
        oldest.statusChangedAt = Date(timeIntervalSince1970: 100)
        newest.statusChangedAt = Date(timeIntervalSince1970: 200)
        unstamped.statusChangedAt = nil // a missing stamp sorts last within the rank group
        #expect(store.attentionSessions.map(\.id) == [newest.id, oldest.id, unstamped.id])
    }

    @Test func attentionSessionsTieBreakStableForEqualAndNilStamps() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let stampedA = store.addSession(toWorkspace: ws.id, cwd: "/sa")!
        let stampedB = store.addSession(toWorkspace: ws.id, cwd: "/sb")!
        let nilA = store.addSession(toWorkspace: ws.id, cwd: "/na")!
        let nilB = store.addSession(toWorkspace: ws.id, cwd: "/nb")!
        // all blocked (same rank); two share an equal stamp, two share a nil stamp — exercising the
        // comparator's (l?, r?)-equal and (nil, nil) branches (both return false). the stamped pair still
        // precedes the nil pair, and within each tie group the stable sort keeps insertion order.
        for s in [stampedA, stampedB, nilA, nilB] { store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: s.id) }
        stampedA.statusChangedAt = Date(timeIntervalSince1970: 500)
        stampedB.statusChangedAt = Date(timeIntervalSince1970: 500) // equal stamp -> stable, keeps order
        nilA.statusChangedAt = nil
        nilB.statusChangedAt = nil
        #expect(store.attentionSessions.map(\.id) == [stampedA.id, stampedB.id, nilA.id, nilB.id])
    }

    @Test func attentionSessionsSpanAllWorkspacesIgnoringFocusAndFlagged() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let other = store.addWorkspace(name: "other")
        let here = store.addSession(toWorkspace: work.id, cwd: "/here")!
        let away = store.addSession(toWorkspace: other.id, cwd: "/away")!
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: here.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: away.id)
        // focusing one workspace must NOT shrink the list — a blocked session in another workspace still shows
        store.setFocusedWorkspace(work.id)
        #expect(store.attentionSessions.map(\.id) == [away.id, here.id]) // blocked(away) before active(here)
        // flagged mode is likewise ignored: nothing is flagged, but the non-idle sessions still list
        store.setSidebarMode(.flagged)
        #expect(store.attentionSessions.map(\.id) == [away.id, here.id])
    }

    @Test func attentionSessionsEmptyWhenAllIdle() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = store.addSession(toWorkspace: ws.id, cwd: "/a")
        _ = store.addSession(toWorkspace: ws.id, cwd: "/b")
        // no statuses set: every session is idle, so the attention list is empty
        #expect(store.attentionSessions.isEmpty)
    }
}
