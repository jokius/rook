import Foundation
import Testing
@testable import rookCore

/// Per-workspace appearance (the sidebar icon color): the store mutator, its persistence, the `tree`
/// read-back, and the close/reopen round-trip.
@MainActor
struct AppStoreAppearanceTests {
    @Test func setWorkspaceColorPersistsAndClears() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rook-tests-\(UUID().uuidString)")
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

    @Test func setWorkspaceIconPersistsAndClears() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rook-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let a = store.addWorkspace(name: "a")
        let icon = WorkspaceIcon(kind: .symbol, value: "hammer.fill")

        store.setWorkspaceIcon(a.id, icon: icon)
        #expect(store.workspaces[0].icon == icon)
        #expect(persistence.load().workspaces[0].icon == icon) // a single event → a plain save()

        store.setWorkspaceIcon(a.id, icon: nil)
        #expect(store.workspaces[0].icon == nil)
        #expect(persistence.load().workspaces[0].icon == nil)
    }

    @Test func setWorkspaceIconUnknownOrUnchangedIsNoOp() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let icon = WorkspaceIcon(kind: .emoji, value: "🚀")
        store.setWorkspaceIcon(UUID(), icon: icon) // unknown id
        #expect(store.workspaces[0].icon == nil)
        store.setWorkspaceIcon(a.id, icon: icon)
        store.setWorkspaceIcon(a.id, icon: icon) // already that icon → clean no-op
        #expect(store.workspaces[0].icon == icon)
    }

    /// Replacing (or clearing) an image icon must LEAVE the previous file in place. `tree` hands a script
    /// the copy's path as the record-then-restore token, and `workspace.icon <that path>` restores it — so
    /// deleting the file on replace would break restoring an image icon (`no such image file`). The cost is
    /// one orphaned file per pick, accepted like the orphan a deleted workspace leaves.
    @Test func replacingAnImageIconKeepsThePreviousFileForRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rook-tests-\(UUID().uuidString)")
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("icon.svg")
        try Data("<svg/>".utf8).write(to: source)

        let store = AppStore(persistence: PersistenceStore(directory: root))
        let ws = store.addWorkspace(name: "a")
        let first = try WorkspaceIconStorage.install(source: source, workspaceID: ws.id, stateDir: stateDir)
        store.setWorkspaceIcon(ws.id, icon: first)

        let second = try WorkspaceIconStorage.install(source: source, workspaceID: ws.id, stateDir: stateDir)
        store.setWorkspaceIcon(ws.id, icon: second)
        #expect(FileManager.default.fileExists(atPath: first.value), "the previous file must survive, so a restore can re-adopt it")
        #expect(FileManager.default.fileExists(atPath: second.value), "the current copy stays too")

        // record-then-restore round-trips: re-installing the FIRST path (still on disk) is idempotent, so
        // the original icon comes back exactly.
        let restored = try WorkspaceIconStorage.install(source: URL(fileURLWithPath: first.value),
                                                        workspaceID: ws.id, stateDir: stateDir)
        store.setWorkspaceIcon(ws.id, icon: restored)
        #expect(store.workspaces[0].icon == first, "the recorded image icon restores exactly")

        store.setWorkspaceIcon(ws.id, icon: nil) // clearing also leaves the file
        #expect(FileManager.default.fileExists(atPath: first.value))
    }

    @Test func controlTreeReportsWorkspaceIconAndKind() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "iconed")
        #expect(store.controlTree().workspaces.allSatisfy { $0.icon == nil && $0.iconKind == nil })

        store.setWorkspaceIcon(ws.id, icon: WorkspaceIcon(kind: .symbol, value: "hammer.fill"))
        let node = store.controlTree().workspaces.first { $0.id == ws.id.uuidString }
        #expect(node?.icon == "hammer.fill")
        #expect(node?.iconKind == "symbol") // the kind says how to read the value

        store.setWorkspaceIcon(ws.id, icon: nil)
        #expect(store.controlTree().workspaces.allSatisfy { $0.icon == nil && $0.iconKind == nil })
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

    /// Same fifth-construction-site trap for the icon: a workspace reopened from Open Recent must come back
    /// with its icon, not the default glyph.
    @Test func reopeningRecentWorkspaceKeepsItsIcon() throws {
        let (store, _, _) = makeStoreWithRecentClosed()
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "keep")
        let session = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        let icon = WorkspaceIcon(kind: .emoji, value: "🚀")
        store.setWorkspaceIcon(doomed.id, icon: icon)
        let snapshot = store.workspaceSnapshot(try #require(store.workspaces.first { $0.id == doomed.id }))
        #expect(snapshot.icon == icon)

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))

        let recent = RecentClosedItem(
            kind: .workspace, title: "doomed", subtitle: "1 session",
            workspace: RecentClosedWorkspace(snapshot: snapshot, selectedSessionID: session.id)
        )
        #expect(store.restoreRecentClosed(recent))
        #expect(store.workspaces.first { $0.id == doomed.id }?.icon == icon)
    }
}
