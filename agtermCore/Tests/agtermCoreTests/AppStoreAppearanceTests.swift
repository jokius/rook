import Foundation
import Testing
@testable import agtermCore

/// Per-workspace appearance (the sidebar icon color): the store mutator, its persistence, the `tree`
/// read-back, and the close/reopen round-trip.
@MainActor
struct AppStoreAppearanceTests {
    @Test func setWorkspaceColorPersistsAndClears() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")

        store.setWorkspaceColor(a.id, hex: "#ff8800")
        store.save() // the color write is DEBOUNCED (the color panel drags continuously); save() flushes it
        #expect(store.workspaces[0].colorHex == "#ff8800")
        #expect(store.workspaces[1].colorHex == nil) // per-workspace, b untouched
        #expect(persistence.load().workspaces[0].colorHex == "#ff8800")

        store.setWorkspaceColor(a.id, hex: nil) // clear → back to the theme default
        store.save()
        #expect(store.workspaces[0].colorHex == nil)
        #expect(persistence.load().workspaces[0].colorHex == nil)
        _ = b
    }

    @Test func setWorkspaceColorUnknownOrUnchangedIsNoOp() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        store.setWorkspaceColor(UUID(), hex: "#ff8800") // unknown id
        #expect(store.workspaces[0].colorHex == nil)
        store.setWorkspaceColor(a.id, hex: "#ff8800")
        store.setWorkspaceColor(a.id, hex: "#ff8800") // already that color → clean no-op
        #expect(store.workspaces[0].colorHex == "#ff8800")
    }

    @Test func controlTreeReportsWorkspaceColor() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "colored")
        // no color: the node omits it (the theme default).
        #expect(store.controlTree().workspaces.allSatisfy { $0.color == nil })
        // set: only that workspace's node carries the hex, so a script can read back what it wrote.
        store.setWorkspaceColor(ws.id, hex: "#ff8800")
        let nodes = store.controlTree().workspaces
        #expect(nodes.first { $0.id == ws.id.uuidString }?.color == "#ff8800")
        #expect(nodes.filter { $0.color != nil }.count == 1)
        // cleared: omitted again.
        store.setWorkspaceColor(ws.id, hex: nil)
        #expect(store.controlTree().workspaces.allSatisfy { $0.color == nil })
    }

    /// The color must survive a close/reopen round-trip. The rebuilt shell (`rebuiltWorkspaceShell`) is a
    /// FIFTH place a `Workspace` is constructed, easy to miss when threading a new field: the workspace
    /// reappears with the right name and comes back GRAY if it drops `colorHex`.
    @Test func reopeningRecentWorkspaceKeepsItsColor() throws {
        let (store, _, _) = makeStoreWithRecentClosed()
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "keep")
        let session = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        store.setWorkspaceColor(doomed.id, hex: "#ff8800")
        let snapshot = store.workspaceSnapshot(try #require(store.workspaces.first { $0.id == doomed.id }))
        #expect(snapshot.colorHex == "#ff8800") // the close snapshot carries the color

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))

        let recent = RecentClosedItem(
            kind: .workspace, title: "doomed", subtitle: "1 session",
            workspace: RecentClosedWorkspace(snapshot: snapshot, selectedSessionID: session.id)
        )
        #expect(store.restoreRecentClosed(recent))
        #expect(store.workspaces.first { $0.id == doomed.id }?.colorHex == "#ff8800")
    }
}
