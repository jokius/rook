import Foundation
import Testing
@testable import rookCore

@MainActor
struct AppStoreDashboardTests {
    @Test func dashboardMembersExpandsSessionsToPaneCells() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        b.hasSplit = true // a split session expands into two cells (primary + split)
        let (members, dropped) = store.dashboardMembers(for: [a.id, b.id], limit: 9)
        #expect(dropped == 0)
        #expect(members == [DashboardMember(session: a.id, surface: .primary),
                            DashboardMember(session: b.id, surface: .primary),
                            DashboardMember(session: b.id, surface: .split)])
        // control refs: a non-split session is one `:left` cell, a split session is `:left` + `:right`.
        #expect(members.map(\.controlRef) ==
                ["\(a.id.uuidString):left", "\(b.id.uuidString):left", "\(b.id.uuidString):right"])
    }

    @Test func dashboardMembersCapsAtLimitAndReportsDropped() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let ids = (0..<5).map { store.addSession(toWorkspace: ws.id, cwd: "/\($0)")!.id }
        let (members, dropped) = store.dashboardMembers(for: ids, limit: 3)
        #expect(members == ids.prefix(3).map { DashboardMember(session: $0, surface: .primary) }) // first 3 kept
        #expect(dropped == 2) // two panes past the cap
    }

    @Test func dashboardMembersSkipsUnresolvedIDs() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let (members, dropped) = store.dashboardMembers(for: [UUID(), a.id, UUID()], limit: 9)
        #expect(dropped == 0)
        #expect(members == [DashboardMember(session: a.id, surface: .primary)]) // only the real id yields a cell
    }

    @Test func dashboardMRUMembersFollowsRecencyOrderAndExpands() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        b.hasSplit = true
        store.selectSession(a.id)
        store.selectSession(b.id) // most-recent-first recency: [b, a]
        #expect(store.dashboardMRUMembers(limit: 9) == [DashboardMember(session: b.id, surface: .primary),
                                                        DashboardMember(session: b.id, surface: .split),
                                                        DashboardMember(session: a.id, surface: .primary)])
    }

    @Test func dashboardMRUMembersEmptyWhenNoSessions() {
        let store = makeStore()
        #expect(store.dashboardMRUMembers(limit: 9).isEmpty) // no sessions → no recent members
    }

    @Test func dashboardMembersHonorsExplicitPaneAndDedupsBySessionPlusPane() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        a.hasSplit = true
        // a bare id takes BOTH panes, `A:left` only the primary — so `A A:left` collapses to the bare id's
        // two cells (dedup is by session+pane), while `A:left A:right` stays two distinct cells.
        let (collapsed, _) = store.dashboardMembers(
            for: [ResolvedDashboardTarget(session: a.id, pane: nil),
                  ResolvedDashboardTarget(session: a.id, pane: .primary)], limit: 9)
        #expect(collapsed == [DashboardMember(session: a.id, surface: .primary),
                              DashboardMember(session: a.id, surface: .split)])

        let (bothPanes, _) = store.dashboardMembers(
            for: [ResolvedDashboardTarget(session: a.id, pane: .primary),
                  ResolvedDashboardTarget(session: a.id, pane: .split)], limit: 9)
        #expect(bothPanes == [DashboardMember(session: a.id, surface: .primary),
                              DashboardMember(session: a.id, surface: .split)])
    }

    @Test func dashboardMembersPaneRefFreesTheOtherCellUnderTheCap() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        a.hasSplit = true
        // the point of the feature: naming one pane of the split leaves room for `b` under a 2-cell cap,
        // where the bare id would have taken both cells and evicted it.
        let (bare, bareDropped) = store.dashboardMembers(for: [a.id, b.id], limit: 2)
        #expect(bare == [DashboardMember(session: a.id, surface: .primary),
                         DashboardMember(session: a.id, surface: .split)])
        #expect(bareDropped == 1) // b never reaches the grid

        let (scoped, scopedDropped) = store.dashboardMembers(
            for: [ResolvedDashboardTarget(session: a.id, pane: .split),
                  ResolvedDashboardTarget(session: b.id, pane: nil)], limit: 2)
        #expect(scoped == [DashboardMember(session: a.id, surface: .split),
                           DashboardMember(session: b.id, surface: .primary)])
        #expect(scopedDropped == 0)
    }
}
