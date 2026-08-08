import Foundation
import Testing
@testable import rookCore

/// Class suite (reference type) so `init`/`deinit` create and tear down a unique
/// temp directory around each test — no shared on-disk state, no Application
/// Support pollution.
@MainActor
final class PersistenceTests {
    private let directory: URL
    private let store: PersistenceStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rook-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = PersistenceStore(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("workspaces.json") }

    /// The first workspace's sessions exactly as they sit in the file. The honest read for a field with no
    /// typed accessor yet — and the same bytes the next launch decodes, so an omitted key reads as omitted
    /// rather than as a nil property.
    private func persistedSessions() throws -> [[String: Any]] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        let workspaces = root?["workspaces"] as? [[String: Any]]
        return workspaces?.first?["sessions"] as? [[String: Any]] ?? []
    }

    @Test func snapshotRoundTripsThroughDisk() throws {
        let original = Snapshot(selectedSessionID: UUID(), workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
                SessionSnapshot(id: UUID(), customName: "build", cwd: "/Users/user/dev/foo"),
                SessionSnapshot(id: UUID(), customName: nil, cwd: "/tmp"),
            ]),
            WorkspaceSnapshot(id: UUID(), name: "personal", sessions: []),
        ])
        try store.save(original)
        let decoded = store.load()
        #expect(decoded == original)
    }

    @Test func appStoreSnapshotCapturesTreeAndCwds() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let session = try! #require(app.addSession(toWorkspace: work.id, cwd: "/start"))
        session.currentCwd = "/Users/user/dev/live"
        app.renameSession(session.id, to: "build")
        let other = try! #require(app.addSession(toWorkspace: work.id, cwd: "/tmp"))

        let snapshot = app.snapshot()
        #expect(snapshot.selectedSessionID == other.id)
        #expect(snapshot.workspaces.count == 1)
        let ws = try! #require(snapshot.workspaces.first)
        #expect(ws.id == work.id)
        #expect(ws.name == "work")
        #expect(ws.sessions.map(\.id) == [session.id, other.id])
        #expect(ws.sessions[0].customName == "build")
        #expect(ws.sessions[0].cwd == "/Users/user/dev/live")
        #expect(ws.sessions[1].cwd == "/tmp")
    }

    @Test func restoreRebuildsTreeNamesAndCwds() {
        let selected = UUID()
        let snapshot = Snapshot(selectedSessionID: selected, workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
                SessionSnapshot(id: selected, customName: "build", cwd: "/Users/user/dev/foo"),
                SessionSnapshot(id: UUID(), customName: nil, cwd: "/var/log"),
            ]),
            WorkspaceSnapshot(id: UUID(), name: "personal", sessions: [
                SessionSnapshot(id: UUID(), customName: nil, cwd: "/"),
            ]),
        ])

        let app = AppStore(persistence: store)
        app.restore(from: snapshot)

        #expect(app.selectedSessionID == selected)
        #expect(app.workspaces.map(\.id) == snapshot.workspaces.map(\.id))
        #expect(app.workspaces.map(\.name) == ["work", "personal"])

        let first = app.workspaces[0]
        #expect(first.sessions.map(\.id) == snapshot.workspaces[0].sessions.map(\.id))
        #expect(first.sessions[0].customName == "build")
        #expect(first.sessions[0].initialCwd == "/Users/user/dev/foo")
        #expect(first.sessions[0].displayName == "build")
        #expect(first.sessions[1].customName == nil)
        #expect(first.sessions[1].initialCwd == "/var/log")
        #expect(first.sessions[1].displayName == "log")
        #expect(app.workspaces[1].sessions[0].displayName == "/")
        // surfaces stay lazy/nil until first display
        #expect(first.sessions[0].surface == nil)
        // currentCwd is nil after restore — only a live PWD report sets it; the
        // persisted cwd becomes initialCwd.
        #expect(first.sessions[0].currentCwd == nil)
        #expect(first.sessions[1].currentCwd == nil)
    }

    @Test func restoreClearsDanglingSelection() {
        let snapshot = Snapshot(selectedSessionID: UUID(), workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
                SessionSnapshot(id: UUID(), customName: nil, cwd: "/a"),
            ]),
        ])
        let app = AppStore(persistence: store)
        app.restore(from: snapshot)
        // the persisted selection points at no existing session, so it's cleared.
        #expect(app.selectedSessionID == nil)
        #expect(app.activeSession == nil)
    }

    @Test func restoreDoesNotWriteToDisk() {
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let snapshot = Snapshot(workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
                SessionSnapshot(id: UUID(), customName: nil, cwd: "/a"),
            ]),
        ])
        let app = AppStore(persistence: store)
        app.restore(from: snapshot)
        // restore loads what was just read from disk; it must not re-persist.
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func snapshotRestoreRoundTripPreservesTree() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let personal = app.addWorkspace(name: "personal")
        app.addSession(toWorkspace: work.id, cwd: "/a")
        let b = try! #require(app.addSession(toWorkspace: personal.id, cwd: "/b"))
        app.renameSession(b.id, to: "server")
        app.selectSession(b.id)

        let snapshot = app.snapshot()
        let restored = AppStore(persistence: store)
        restored.restore(from: snapshot)
        #expect(restored.snapshot() == snapshot)
    }

    @Test func hudStateNeverReachesTheSnapshot() throws {
        let app = AppStore(persistence: store)
        let ws = app.addWorkspace(name: "work")
        let session = try #require(app.addSession(toWorkspace: ws.id, cwd: "/a"))
        session.overlayActive = true
        session.overlaySizePercent = 30
        session.hudSpec = HudSpec(message: "gathering options", detail: "scanning /a", spinner: .bar)
        session.hudFile = "/tmp/rook-hud-test.txt"

        let snap = app.snapshot()
        let json = String(decoding: try JSONEncoder().encode(snap), as: UTF8.self)
        #expect(!json.contains("hud"))
        #expect(!json.contains("gathering options"))

        let restored = AppStore(persistence: store)
        restored.restore(from: snap)
        let r = restored.workspaces[0].sessions[0]
        #expect(r.hudSpec == nil)
        #expect(r.hudFile == nil)
        #expect(r.hudActive == false)
        #expect(r.overlayActive == false)
    }

    @Test func legacyFileWithRemovedKeysLoadsAndKeepsWorkspaces() throws {
        // a workspaces.json written by an older build carries removed keys (statusBarHidden,
        // titleBarHidden). they must be ignored, not fail the load and wipe the tree.
        let id = UUID()
        let json = #"{ "version": 1, "statusBarHidden": true, "titleBarHidden": true, "workspaces": [ { "id": "\#(id.uuidString)", "name": "work", "sessions": [] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.workspaces.map(\.id) == [id])
    }

    @Test func sessionSplitStatePersistsAndRestores() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let session = try! #require(app.addSession(toWorkspace: work.id, cwd: "/a"))
        app.toggleSplit(session.id)
        #expect(store.load().workspaces[0].sessions[0].isSplit == true)

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.workspaces[0].sessions[0].isSplit == true)
    }

    @Test func sessionFlaggedStatePersistsAndRestores() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let flag = try! #require(app.addSession(toWorkspace: work.id, cwd: "/a"))
        let plain = try! #require(app.addSession(toWorkspace: work.id, cwd: "/b"))
        flag.flagged = true
        app.save()
        #expect(store.load().workspaces[0].sessions[0].flagged == true)
        #expect(store.load().workspaces[0].sessions[1].flagged == false)

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.workspaces[0].sessions[0].flagged == true)
        #expect(restored.workspaces[0].sessions[1].flagged == false)
        _ = plain
    }

    @Test func legacySnapshotWithoutFlaggedDecodesUnflagged() throws {
        // a workspaces.json written before `flagged` existed has no key; it must decode (not throw and
        // wipe the tree) with the session unflagged.
        let ws = UUID()
        let sid = UUID()
        let json = #"{ "version": 1, "workspaces": [ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [ { "id": "\#(sid.uuidString)", "customName": null, "cwd": "/a" } ] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.workspaces.map(\.id) == [ws])
        #expect(loaded.workspaces[0].sessions[0].flagged == nil)

        let app = AppStore(persistence: store)
        app.restore(from: loaded)
        #expect(app.workspaces[0].sessions[0].flagged == false)
    }

    @Test func sidebarModePersistsAndRestores() {
        let app = AppStore(persistence: store)
        _ = app.addWorkspace(name: "work")
        #expect(store.load().sidebarMode == .tree)
        app.setSidebarMode(.flagged)
        #expect(store.load().sidebarMode == .flagged)

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.sidebarMode == .flagged)

        app.setSidebarMode(.tree)
        let restoredTree = AppStore(persistence: store)
        restoredTree.restore(from: store.load())
        #expect(restoredTree.sidebarMode == .tree)
    }

    @Test func sidebarVisibilityPersistsAndRestoresThroughHelper() {
        let app = AppStore(persistence: store)
        _ = app.addWorkspace(name: "work")
        #expect(store.load().sidebarVisible == true)
        app.setSidebarVisible(false)
        #expect(store.load().sidebarVisible == false)

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.sidebarVisible == false)

        app.toggleSidebarVisible()
        let restoredShown = AppStore(persistence: store)
        restoredShown.restore(from: store.load())
        #expect(restoredShown.sidebarVisible == true)
    }

    @Test func legacySnapshotWithoutSidebarModeDecodesTree() throws {
        // a workspaces.json written before `sidebarMode` existed has no key; it must decode (not throw
        // and wipe the tree) and restore to `.tree`.
        let ws = UUID()
        let json = #"{ "version": 1, "workspaces": [ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.workspaces.map(\.id) == [ws])
        #expect(loaded.sidebarMode == nil)

        let app = AppStore(persistence: store)
        app.restore(from: loaded)
        #expect(app.sidebarMode == .tree)
    }

    // MARK: - the focus SET and the three migration generations

    @Test func focusSetPersistsAndRestores() throws {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        // nothing marked: BOTH keys are omitted, so the file stays byte-identical to one written before
        // the set existed.
        #expect(store.load().focusedWorkspaceIDs == nil)
        #expect(store.load().focusEnabled == nil)
        let bare = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!bare.contains("focusedWorkspaceIDs"))
        #expect(!bare.contains("focusEnabled"))

        app.setFocusedWorkspace(work.id)
        #expect(store.load().focusedWorkspaceIDs == [work.id])
        #expect(store.load().focusEnabled == true) // the replacing Focus persists BOTH the member and the flag

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.focusedWorkspaceIDs == [work.id])
        #expect(restored.focusEnabled)
        #expect(restored.visibleWorkspaces.map(\.id) == [work.id])

        app.clearFocus() // an EXPLICIT clear forgets the members, on disk too
        #expect(store.load().focusedWorkspaceIDs == nil)
        #expect(store.load().focusEnabled == nil)
        let restoredCleared = AppStore(persistence: store)
        restoredCleared.restore(from: store.load())
        #expect(restoredCleared.focusedWorkspaceIDs.isEmpty)
        #expect(!restoredCleared.focusEnabled)
    }

    @Test func aMultiMemberFocusSetPersistsInTreeOrderAndSurvivesARoundTrip() {
        let app = AppStore(persistence: store)
        let a = app.addWorkspace(name: "a")
        let b = app.addWorkspace(name: "b")
        let c = app.addWorkspace(name: "c")
        app.setFocusMembership(c.id, member: true) // marked LAST-first: the file must not follow that order…
        app.setFocusMembership(a.id, member: true)
        #expect(!app.focusEnabled) // …and marking alone never applies the filter
        #expect(store.load().focusedWorkspaceIDs == [a.id, c.id]) // …nor the Set's hash order — TREE order
        #expect(store.load().focusEnabled == nil)

        app.setFocusEnabled(true)
        #expect(store.load().focusEnabled == true)

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.focusedWorkspaceIDs == [a.id, c.id])
        #expect(restored.focusEnabled)
        #expect(restored.visibleWorkspaces.map(\.id) == [a.id, c.id])
        #expect(restored.soleFocusedWorkspaceID == nil) // two members zoom to nothing in particular
        _ = b
    }

    @Test func markSurvivesAnInvoluntaryJumpAcrossARelaunch() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let personal = app.addWorkspace(name: "personal")
        _ = app.addSession(toWorkspace: work.id, cwd: "/a")
        let outside = try! #require(app.addSession(toWorkspace: personal.id, cwd: "/b"))
        app.setFocusedWorkspace(work.id)
        app.selectSession(outside.id) // idle auto-follow / a notification reveal: the filter drops, the set stays
        app.save() // selection saves are debounced; flush so the write lands before reading back

        // the file keeps BOTH bits SEPARATELY: the flag goes off, and the marked set rides alongside it
        // instead of being lost with the filter.
        let onDisk = store.load()
        #expect(onDisk.focusEnabled == nil)
        #expect(onDisk.focusedWorkspaceIDs == [work.id])

        let restored = AppStore(persistence: store)
        restored.restore(from: onDisk)
        #expect(!restored.focusEnabled) // comes back unfiltered, exactly as it was left
        #expect(restored.focusedWorkspaceIDs == [work.id])
        #expect(restored.visibleWorkspaces.map(\.id) == [work.id, personal.id])
        restored.setFocusEnabled(true) // `workspace.filter on` after the relaunch...
        #expect(restored.soleFocusedWorkspaceID == work.id) // ...returns to the SAME workspace
        #expect(restored.visibleWorkspaces.map(\.id) == [work.id])
    }

    @Test func legacySnapshotWithoutMarkedWorkspaceRestoresAFilteringFocus() throws {
        // MIGRATION (a), the ANCIENT shape: a workspaces.json written before `markedWorkspaceID` existed
        // carries only the effective id, and that field MEANT "the tree is collapsed to this workspace" —
        // so it must decode (not throw and wipe the tree) as a one-member set that IS filtering,
        // bit-for-bit what the old build restored, so the migration is invisible to the user.
        let ws = UUID()
        let json = #"{ "version": 1, "focusedWorkspaceID": "\#(ws.uuidString)", "workspaces": "# +
            #"[ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.workspaces.map(\.id) == [ws])
        #expect(loaded.focusedWorkspaceIDs == [ws])
        #expect(loaded.focusEnabled == true)

        let app = AppStore(persistence: store)
        app.restore(from: loaded)
        #expect(app.focusedWorkspaceIDs == [ws])
        #expect(app.focusEnabled)
        #expect(app.soleFocusedWorkspaceID == ws)
        #expect(app.visibleWorkspaces.map(\.id) == [ws])
    }

    @Test func legacyMarkAndEffectiveFocusMigrateOntoTheSetAndTheFlagSeparately() throws {
        // MIGRATION (b): the split shipped in 62097fb and LIVE IN REAL USER FILES TODAY — the MARK is the
        // set, the effective id is only the FLAG. Reading the effective id as the set (the obvious
        // migration) would restore an EMPTY set for the second shape below, which is the exact state an
        // involuntary jump leaves behind — the one the split exists to persist.
        let ws = UUID()
        let tree = #""workspaces": [ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [] } ]"#

        // both keys set: marked AND filtering.
        try Data(#"{ "version": 1, "focusedWorkspaceID": "\#(ws.uuidString)", "markedWorkspaceID": "\#(ws.uuidString)", \#(tree) }"#.utf8)
            .write(to: fileURL)
        let filtering = store.load()
        #expect(filtering.focusedWorkspaceIDs == [ws])
        #expect(filtering.focusEnabled == true)

        // the LOAD-BEARING shape: the mark outlived the filter. The set keeps the workspace; only the flag
        // is off.
        try Data(#"{ "version": 1, "focusedWorkspaceID": null, "markedWorkspaceID": "\#(ws.uuidString)", \#(tree) }"#.utf8)
            .write(to: fileURL)
        let suspended = store.load()
        #expect(suspended.workspaces.map(\.id) == [ws])
        #expect(suspended.focusedWorkspaceIDs == [ws], "the mark must NOT be dropped with the filter")
        #expect(suspended.focusEnabled == nil)

        let app = AppStore(persistence: store)
        app.restore(from: suspended)
        #expect(app.focusedWorkspaceIDs == [ws])
        #expect(!app.focusEnabled)
        app.setFocusEnabled(true) // `workspace.filter on` after the upgrade returns to the same workspace
        #expect(app.soleFocusedWorkspaceID == ws)
        #expect(app.visibleWorkspaces.map(\.id) == [ws])
    }

    @Test func theNewFocusKeysWinOverAnyLegacyKeyInTheSameFile() throws {
        // MIGRATION (c): the new keys pass through verbatim, and a legacy key left in the same file (a
        // downgrade-then-upgrade, a hand edit) is IGNORED rather than fighting them.
        let a = UUID()
        let b = UUID()
        let stray = UUID()
        let tree = #""workspaces": [ { "id": "\#(a.uuidString)", "name": "a", "sessions": [] }, "# +
            #"{ "id": "\#(b.uuidString)", "name": "b", "sessions": [] } ]"#
        let json = #"{ "version": 1, "focusedWorkspaceIDs": ["\#(a.uuidString)", "\#(b.uuidString)"], "focusEnabled": true, "# +
            #""focusedWorkspaceID": "\#(stray.uuidString)", "markedWorkspaceID": "\#(stray.uuidString)", \#(tree) }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.focusedWorkspaceIDs == [a, b])
        #expect(loaded.focusEnabled == true)

        let app = AppStore(persistence: store)
        app.restore(from: loaded)
        #expect(app.focusedWorkspaceIDs == [a, b])
        #expect(app.visibleWorkspaces.map(\.id) == [a, b])

        // the legacy read is gated on BOTH new keys being absent, so a file carrying only `focusEnabled`
        // still ignores the legacy id rather than half-migrating.
        let flagOnly = #"{ "version": 1, "focusEnabled": false, "focusedWorkspaceID": "\#(stray.uuidString)", \#(tree) }"#
        try Data(flagOnly.utf8).write(to: fileURL)
        #expect(store.load().focusedWorkspaceIDs == nil)
        #expect(store.load().focusEnabled == false)
    }

    @Test func aMigratedSnapshotNeverWritesTheLegacyFocusKeysBack() throws {
        // the legacy keys live in their own key type with no stored property, so the first load-mutate-save
        // after the upgrade drops them — otherwise every future save would keep re-emitting a field whose
        // meaning has changed.
        let ws = UUID()
        let json = #"{ "version": 1, "focusedWorkspaceID": "\#(ws.uuidString)", "markedWorkspaceID": "\#(ws.uuidString)", "# +
            #""workspaces": [ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [] } ] }"#
        try Data(json.utf8).write(to: fileURL)

        try store.save(store.load()) // re-encode exactly what was migrated
        // read the KEYS back rather than grepping the text: `focusedWorkspaceIDs` contains the legacy key
        // as a prefix, so a substring check could never fail.
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
        let fields = try #require(object as? [String: Any])
        let keys = Set(fields.keys)
        #expect(!keys.contains("focusedWorkspaceID"), "the legacy effective-id key must not come back")
        #expect(!keys.contains("markedWorkspaceID"), "nor the legacy mark key")
        #expect(keys.contains("focusedWorkspaceIDs"))
        #expect(keys.contains("focusEnabled"))
        // and the migrated value is unchanged by the rewrite
        #expect(store.load().focusedWorkspaceIDs == [ws])
        #expect(store.load().focusEnabled == true)
    }

    @Test func snapshotWithoutAnyFocusKeyDecodesUnfocusedAndKeepsTheTree() throws {
        // a workspaces.json with no focus key at all (any build before the filter existed) must decode —
        // never throw and make `load()` start fresh, wiping the saved tree — and restore unfocused.
        let ws = UUID()
        let json = #"{ "version": 1, "workspaces": [ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.workspaces.map(\.id) == [ws])
        #expect(loaded.focusedWorkspaceIDs == nil)
        #expect(loaded.focusEnabled == nil)

        let app = AppStore(persistence: store)
        app.restore(from: loaded)
        #expect(app.focusedWorkspaceIDs.isEmpty)
        #expect(!app.focusEnabled)
        #expect(app.visibleWorkspaces.map(\.id) == [ws])
    }

    @Test func restoredMarkOfARemovedWorkspaceShowsTheWholeTree() {
        let ws = UUID()
        let gone = UUID()
        let app = AppStore(persistence: store)
        app.restore(from: Snapshot(workspaces: [WorkspaceSnapshot(id: ws, name: "work", sessions: [])],
                                   focusedWorkspaceIDs: [gone], focusEnabled: true))
        // every member's workspace was removed between the save and the load (another window, a hand edit):
        // the set is PRUNED empty and the flag goes with it, because an enabled-but-invisible filter would
        // make the `focused`/`workspaceFilter` read-back lie.
        #expect(app.focusedWorkspaceIDs.isEmpty)
        #expect(!app.focusEnabled)
        #expect(app.soleFocusedWorkspaceID == nil)
        #expect(app.visibleWorkspaces.map(\.id) == [ws])
        app.setFocusEnabled(true)
        #expect(!app.focusEnabled) // re-enabling refuses an empty set

        // the same clamp for a file that states the impossible pair outright
        let handEdited = AppStore(persistence: store)
        handEdited.restore(from: Snapshot(workspaces: [WorkspaceSnapshot(id: ws, name: "work", sessions: [])],
                                          focusedWorkspaceIDs: [], focusEnabled: true))
        #expect(handEdited.focusedWorkspaceIDs.isEmpty)
        #expect(!handEdited.focusEnabled)
    }

    @Test func restorePrunesStaleMembersAndKeepsTheSurvivorsFiltering() {
        let live = UUID()
        let alsoLive = UUID()
        let gone = UUID()
        let app = AppStore(persistence: store)
        app.restore(from: Snapshot(workspaces: [
            WorkspaceSnapshot(id: live, name: "work", sessions: []),
            WorkspaceSnapshot(id: alsoLive, name: "personal", sessions: []),
        ], focusedWorkspaceIDs: [live, gone], focusEnabled: true))
        // a PARTIALLY stale set keeps its survivors and stays enabled — only the unresolvable id is dropped.
        #expect(app.focusedWorkspaceIDs == [live])
        #expect(app.focusEnabled)
        #expect(app.soleFocusedWorkspaceID == live)
        #expect(app.visibleWorkspaces.map(\.id) == [live])
    }

    @Test func sessionRecencyPersistsAndRestores() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let a = try! #require(app.addSession(toWorkspace: work.id, cwd: "/a"))
        let b = try! #require(app.addSession(toWorkspace: work.id, cwd: "/b"))
        let c = try! #require(app.addSession(toWorkspace: work.id, cwd: "/c"))
        app.selectSession(a.id)
        app.selectSession(b.id)
        app.save() // selection saves are debounced; flush so the write lands before reading back
        #expect(store.load().sessionRecency == [b.id, a.id, c.id])

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.sessionRecency.items == [b.id, a.id, c.id])
    }

    @Test func restoreDropsStaleRecencyIds() {
        let id = UUID()
        let stale = UUID()
        let snapshot = Snapshot(selectedSessionID: id, workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
                SessionSnapshot(id: id, customName: nil, cwd: "/a"),
            ]),
        ], sessionRecency: [stale, id])
        let app = AppStore(persistence: store)
        app.restore(from: snapshot)
        // the stale id points at no restored session; it must never reach the switcher.
        #expect(app.sessionRecency.items == [id])
    }

    @Test func restoreFloatsSelectionToRecencyFront() {
        let a = UUID()
        let b = UUID()
        let snapshot = Snapshot(selectedSessionID: b, workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
                SessionSnapshot(id: a, customName: nil, cwd: "/a"),
                SessionSnapshot(id: b, customName: nil, cwd: "/b"),
            ]),
        ], sessionRecency: [a, b])
        let app = AppStore(persistence: store)
        app.restore(from: snapshot)
        // a hand-edited/out-of-sync order still puts the restored selection first.
        #expect(app.sessionRecency.items == [b, a])
    }

    @Test func malformedRecencyDropsToNilKeepingTree() throws {
        // a present-but-invalid sessionRecency (hand-edit typo, wrong type) must drop to nil
        // lossily — never fail the whole Snapshot decode and wipe the tree on the next save.
        let ws = UUID()
        let session = UUID()
        let tree = #""selectedSessionID": "\#(session.uuidString)", "workspaces": "# +
            #"[ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [ { "id": "\#(session.uuidString)", "cwd": "/a" } ] } ]"#
        for bad in [#""sessionRecency": ["not-a-uuid"]"#, #""sessionRecency": 42"#] {
            try Data(#"{ "version": 1, \#(bad), \#(tree) }"#.utf8).write(to: fileURL)
            let loaded = store.load()
            #expect(loaded.workspaces.map(\.id) == [ws])
            #expect(loaded.selectedSessionID == session)
            #expect(loaded.sessionRecency == nil)
        }
    }

    @Test func malformedSidebarModeDropsToNilKeepingTree() throws {
        // an unknown sidebarMode raw value (written by a NEWER build, or a hand edit) must drop to nil
        // lossily — never fail the whole Snapshot decode and wipe the tree over a display field.
        let ws = UUID()
        let session = UUID()
        let tree = #""selectedSessionID": "\#(session.uuidString)", "workspaces": "# +
            #"[ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [ { "id": "\#(session.uuidString)", "cwd": "/a" } ] } ]"#
        for bad in [#""sidebarMode": "hologram""#, #""sidebarMode": 42"#] {
            try Data(#"{ "version": 1, \#(bad), \#(tree) }"#.utf8).write(to: fileURL)
            let loaded = store.load()
            #expect(loaded.workspaces.map(\.id) == [ws], "\(bad) wiped the tree")
            #expect(loaded.selectedSessionID == session)
            #expect(loaded.sidebarMode == nil)
        }
    }

    @Test func malformedTopLevelOptionalsDropToNilKeepingTree() throws {
        // every optional on `Snapshot` must survive a wrong JSON type or a malformed UUID from a hand edit.
        // Only `version` and `workspaces` are strict — the payload itself — so none of these may take the
        // tree down with them. Each case asserts the field it NILLED: a guard that recovered to a wrong
        // non-nil default would still keep the tree alive and pass a tree-only assertion.
        let ws = UUID()
        let session = UUID()
        let tree = #""workspaces": "# +
            #"[ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [ { "id": "\#(session.uuidString)", "cwd": "/a" } ] } ]"#
        let cases: [(bad: String, nilled: (Snapshot) -> Bool)] = [
            (#""selectedSessionID": "not-a-uuid""#, { $0.selectedSessionID == nil }),
            (#""sidebarWidth": "wide""#, { $0.sidebarWidth == nil }),
            (#""fileTreeWidth": "wide""#, { $0.fileTreeWidth == nil }),
            (#""markdownWidth": "wide""#, { $0.markdownWidth == nil }),
            (#""sidebarVisible": "yes""#, { $0.sidebarVisible == nil }),
            (#""focusedWorkspaceIDs": ["not-a-uuid"]"#, { $0.focusedWorkspaceIDs == nil }),
            (#""focusedWorkspaceIDs": 42"#, { $0.focusedWorkspaceIDs == nil }),
            (#""focusEnabled": 42"#, { $0.focusEnabled == nil }),
            (#""focusedWorkspaceID": "not-a-uuid""#, { $0.focusedWorkspaceIDs == nil && $0.focusEnabled == nil }),
            (#""markedWorkspaceID": "not-a-uuid""#, { $0.focusedWorkspaceIDs == nil && $0.focusEnabled == nil }),
        ]
        for (bad, nilled) in cases {
            try Data(#"{ "version": 1, \#(bad), \#(tree) }"#.utf8).write(to: fileURL)
            let loaded = store.load()
            #expect(loaded.workspaces.map(\.id) == [ws], "\(bad) wiped the tree")
            #expect(loaded.workspaces.first?.sessions.map(\.id) == [session], "\(bad) wiped the sessions")
            #expect(nilled(loaded), "\(bad) did not drop its field to nil")
        }
    }

    @Test func malformedSessionAndWorkspaceOptionalsDropToNilKeepingTree() throws {
        // a bad optional NESTED in a session/workspace is the wider surface: it fails its own snapshot,
        // which fails the `workspaces` array above it, and `load()` starts fresh — the whole tree gone over
        // one session's font size. Each nested optional guards itself; only identity and payload throw.
        let ws = UUID()
        let session = UUID()
        let sessionCases: [(bad: String, nilled: (SessionSnapshot) -> Bool)] = [
            (#""customName": 7"#, { $0.customName == nil }),
            (#""isSplit": 1"#, { $0.isSplit == nil }),
            (#""fontSize": "12""#, { $0.fontSize == nil }),
            (#""splitCwd": 3"#, { $0.splitCwd == nil }),
            (#""splitRatio": "half""#, { $0.splitRatio == nil }),
            (#""flagged": "true""#, { $0.flagged == nil }),
            (#""foregroundCommand": "vim""#, { $0.foregroundCommand == nil }),
            (#""splitForegroundCommand": "vim""#, { $0.splitForegroundCommand == nil }),
            (#""agentSession": "claude""#, { $0.agentSession == nil }),
            (#""splitAgentSession": "claude""#, { $0.splitAgentSession == nil }),
            (#""initialCommand": ["vim"]"#, { $0.initialCommand == nil }),
            (#""commandWait": "no""#, { $0.commandWait == nil }),
            (#""backgroundWatermark": "none""#, { $0.backgroundWatermark == nil }),
            (#""fileTreeVisible": "yes""#, { $0.fileTreeVisible == nil }),
            (#""markdownPath": 5"#, { $0.markdownPath == nil }),
            (#""restoreCommand": []"#, { $0.restoreCommand == nil }),
            (#""splitRestoreCommand": 0"#, { $0.splitRestoreCommand == nil }),
        ]
        for (bad, nilled) in sessionCases {
            let tree = #""workspaces": [ { "id": "\#(ws.uuidString)", "name": "work", "sessions": "# +
                #"[ { "id": "\#(session.uuidString)", "cwd": "/a", \#(bad) } ] } ]"#
            try Data(#"{ "version": 1, \#(tree) }"#.utf8).write(to: fileURL)
            let loaded = store.load()
            let restored = try #require(loaded.workspaces.first?.sessions.first, "\(bad) wiped the tree")
            #expect(restored.id == session)
            #expect(restored.cwd == "/a", "\(bad) must not disturb the fields around it")
            #expect(nilled(restored), "\(bad) did not drop its field to nil")
        }

        let workspaceCases: [(bad: String, nilled: (WorkspaceSnapshot) -> Bool)] = [
            (#""collapsed": "yes""#, { $0.collapsed == nil }),
            (#""colorHex": 16"#, { $0.colorHex == nil }),
            (#""root": []"#, { $0.root == nil }),
        ]
        for (bad, nilled) in workspaceCases {
            let tree = #""workspaces": [ { "id": "\#(ws.uuidString)", "name": "work", \#(bad), "# +
                #""sessions": [ { "id": "\#(session.uuidString)", "cwd": "/a" } ] } ]"#
            try Data(#"{ "version": 1, \#(tree) }"#.utf8).write(to: fileURL)
            let loaded = store.load()
            let restored = try #require(loaded.workspaces.first, "\(bad) wiped the tree")
            #expect(restored.sessions.map(\.id) == [session], "\(bad) wiped the sessions")
            #expect(nilled(restored), "\(bad) did not drop its field to nil")
        }
    }

    @Test func aMalformedFocusSetLeavesTheLegacyKeysUnmigrated() throws {
        // now that the new focus keys decode lossily, a FAILED decode must NOT read as an ABSENT key: the
        // legacy migration is gated on absence, and firing it here would resurrect the legacy mark and
        // override the explicit `focusEnabled` in the same file — inventing a filter state the file never
        // stated. `try?` alone cannot tell the two apart (SE-0230 flattens both to nil); `Result` can.
        let ws = UUID()
        let session = UUID()
        let legacy = UUID()
        let tree = #""workspaces": "# +
            #"[ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [ { "id": "\#(session.uuidString)", "cwd": "/a" } ] } ]"#
        let legacyKeys = #""focusedWorkspaceID": "\#(legacy.uuidString)", "markedWorkspaceID": "\#(legacy.uuidString)""#

        // a malformed SET alongside an explicit `focusEnabled: false`
        let badSet = #"{ "version": 1, \#(legacyKeys), "focusedWorkspaceIDs": 42, "focusEnabled": false, \#(tree) }"#
        try Data(badSet.utf8).write(to: fileURL)
        let withBadSet = store.load()
        #expect(withBadSet.workspaces.map(\.id) == [ws])
        #expect(withBadSet.focusedWorkspaceIDs == nil, "a malformed set must not fall back to the legacy mark")
        #expect(withBadSet.focusEnabled == false, "nor override the flag the file states")

        // and the mirror case: a malformed FLAG alongside an explicit set
        let badFlag = #"{ "version": 1, \#(legacyKeys), "focusedWorkspaceIDs": ["\#(ws.uuidString)"], "focusEnabled": "yes", \#(tree) }"#
        try Data(badFlag.utf8).write(to: fileURL)
        let withBadFlag = store.load()
        #expect(withBadFlag.focusedWorkspaceIDs == [ws], "the valid set stands")
        #expect(withBadFlag.focusEnabled == nil, "the malformed flag drops to nil, not to the legacy true")
    }

    @Test func restoreInsertsAbsentSelectionAtFront() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let snapshot = Snapshot(selectedSessionID: c, workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
                SessionSnapshot(id: a, customName: nil, cwd: "/a"),
                SessionSnapshot(id: b, customName: nil, cwd: "/b"),
                SessionSnapshot(id: c, customName: nil, cwd: "/c"),
            ]),
        ], sessionRecency: [a, b])
        let app = AppStore(persistence: store)
        app.restore(from: snapshot)
        // a selection missing from the persisted seed is inserted at the FRONT, not appended.
        #expect(app.sessionRecency.items == [c, a, b])
    }

    @Test func legacySnapshotWithoutRecencyDecodesSelectionOnly() throws {
        // a workspaces.json written before `sessionRecency` existed has no key; it must decode (not
        // throw and wipe the tree) and restore with just the selection in the Ctrl-Tab order.
        let ws = UUID()
        let session = UUID()
        let json = #"{ "version": 1, "selectedSessionID": "\#(session.uuidString)", "workspaces": "# +
            #"[ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [ { "id": "\#(session.uuidString)", "cwd": "/a" } ] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.sessionRecency == nil)

        let app = AppStore(persistence: store)
        app.restore(from: loaded)
        #expect(app.sessionRecency.items == [session])
    }

    @Test func sessionFontSizePersistsAndRestores() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let session = try! #require(app.addSession(toWorkspace: work.id, cwd: "/a"))
        app.setFontSize(session.id, 17.5)
        app.save() // font saves are debounced; flush so the write lands before reading back
        #expect(store.load().workspaces[0].sessions[0].fontSize == 17.5)

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.workspaces[0].sessions[0].fontSize == 17.5)
    }

    @Test func workspaceCollapsePersistsAndRestores() {
        let app = AppStore(persistence: store)
        let a = app.addWorkspace(name: "a")
        let b = app.addWorkspace(name: "b")
        app.setWorkspacesExpanded([a.id]) // collapse b, keep a expanded
        let disk = store.load()
        #expect(disk.workspaces[0].collapsed == nil)  // expanded → omitted
        #expect(disk.workspaces[1].collapsed == true) // collapsed → written

        let restored = AppStore(persistence: store)
        restored.restore(from: disk)
        #expect(restored.workspaces[0].isExpanded)     // a
        #expect(!restored.workspaces[1].isExpanded)    // b
        _ = b
    }

    @Test func legacyWorkspaceWithoutCollapsedDecodesExpanded() throws {
        // a workspaces.json written before `collapsed` existed has no key; it must decode (not throw and
        // wipe the tree) and restore expanded — lack of the field means expanded, for back-compat.
        let ws = UUID()
        let session = UUID()
        let json = #"{ "version": 1, "workspaces": "# +
            #"[ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [ { "id": "\#(session.uuidString)", "cwd": "/a" } ] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.workspaces.map(\.id) == [ws])
        #expect(loaded.workspaces[0].collapsed == nil)

        let app = AppStore(persistence: store)
        app.restore(from: loaded)
        #expect(app.workspaces[0].isExpanded)
    }

    @Test func legacyWorkspaceWithoutColorDecodesUncolored() throws {
        // the same forward-compat contract for `colorHex`: an existing workspaces.json has no key, so it
        // must decode (never throw and wipe the tree) and restore with the theme-default icon tint.
        let ws = UUID()
        let session = UUID()
        let json = #"{ "version": 1, "workspaces": "# +
            #"[ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [ { "id": "\#(session.uuidString)", "cwd": "/a" } ] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.workspaces[0].colorHex == nil)

        let app = AppStore(persistence: store)
        app.restore(from: loaded)
        #expect(app.workspaces[0].colorHex == nil)
    }

    @Test func workspaceColorRoundTripsThroughDisk() throws {
        let app = AppStore(persistence: store)
        let ws = app.addWorkspace(name: "work")
        app.setWorkspaceColor(ws.id, hex: "#ff8800")
        app.save() // the color write is debounced; save() flushes it

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.workspaces.first { $0.id == ws.id }?.colorHex == "#ff8800")
    }

    /// A poisoned icon must not take the whole tree down with it. `Optional` alone tolerates only a MISSING
    /// key, so an unknown `kind` (a hand-edit, or a downgrade from a build that added an icon kind this one
    /// can't read) would fail the entire snapshot and `load()` would start fresh — wiping every workspace
    /// and session over a decorative field.
    @Test func poisonedWorkspaceIconDecodesToNilInsteadOfWipingTheTree() throws {
        let ws = UUID()
        let session = UUID()
        let json = #"{ "version": 1, "workspaces": [ { "id": "\#(ws.uuidString)", "name": "work", "# +
            #""icon": { "kind": "hologram", "value": "x" }, "# +
            #""sessions": [ { "id": "\#(session.uuidString)", "cwd": "/a" } ] } ] }"#
        try Data(json.utf8).write(to: fileURL)

        let loaded = store.load()
        #expect(loaded.workspaces.map(\.id) == [ws], "the tree must survive an unreadable icon")
        #expect(loaded.workspaces[0].icon == nil, "the bad icon drops to nil")
        #expect(loaded.workspaces[0].sessions.count == 1, "and the sessions are intact")
    }

    @Test func workspaceIconRoundTripsThroughDisk() throws {
        let app = AppStore(persistence: store)
        let ws = app.addWorkspace(name: "work")
        let icon = WorkspaceIcon(kind: .symbol, value: "hammer.fill")
        app.setWorkspaceIcon(ws.id, icon: icon)

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.workspaces.first { $0.id == ws.id }?.icon == icon)
    }

    @Test func workspaceSnapshotRoundTripsRoot() throws {
        // the per-workspace root persists like colorHex/icon — an optional field, no version bump.
        let snap = WorkspaceSnapshot(id: UUID(), name: "work", sessions: [], root: "/Users/me/proj")
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snap))
        #expect(decoded == snap)
        #expect(decoded.root == "/Users/me/proj")
        // a nil root is omitted from the JSON (omit-when-nil), keeping the snapshot minimal.
        let bare = WorkspaceSnapshot(id: UUID(), name: "work", sessions: [])
        let json = String(decoding: try JSONEncoder().encode(bare), as: UTF8.self)
        #expect(!json.contains("\"root\""))
    }

    @Test func workspaceSnapshotLegacyDecodesWithoutRoot() throws {
        // a snapshot written before `root` existed (no version bump) still decodes, with root nil.
        let json = #"{ "id": "\#(UUID().uuidString)", "name": "work", "sessions": [] }"#
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
        #expect(decoded.root == nil)
    }

    @Test func workspaceRootRoundTripsThroughDisk() throws {
        let app = AppStore(persistence: store)
        let ws = app.addWorkspace(name: "work")
        app.setWorkspaceRoot(ws.id, path: "/Users/me/proj")
        app.save() // flush in case the write is debounced

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.workspaces.first { $0.id == ws.id }?.root == "/Users/me/proj")
    }

    @Test func sessionShellRoundTripsThroughDisk() throws {
        // the persistence leg of `session.new --shell`: a fish session must come back fish after a relaunch,
        // not on the app's own shell. Read on the WIRE (the file's own JSON) rather than through a typed
        // field — what the next launch decodes IS the bytes on disk, so a save that quietly drops the shell
        // is exactly the failure this guards.
        let ws = UUID()
        let session = UUID()
        let json = #"{ "version": 1, "workspaces": [ { "id": "\#(ws.uuidString)", "name": "work", "sessions": "# +
            #"[ { "id": "\#(session.uuidString)", "cwd": "/a", "shell": "/opt/homebrew/bin/fish" } ] } ] }"#
        try Data(json.utf8).write(to: fileURL)

        let app = AppStore(persistence: store)
        app.restore(from: store.load())
        app.save()

        let persisted = try #require(persistedSessions().first, "the session must survive the round trip")
        #expect(persisted["shell"] as? String == "/opt/homebrew/bin/fish")
        #expect(persisted["cwd"] as? String == "/a", "the shell must not disturb the fields around it")
    }

    @Test func legacySessionWithoutShellDecodesAndStaysKeyless() throws {
        // the forward-compat contract `colorHex`/`root` already follow, on the session side: an existing
        // workspaces.json has no `shell` key, so it must decode (never throw and wipe the tree) as "the
        // app's default shell" — and re-save WITHOUT inventing one, so nothing about the file changes for a
        // user who never asked for a per-session shell.
        let ws = UUID()
        let session = UUID()
        let json = #"{ "version": 1, "workspaces": [ { "id": "\#(ws.uuidString)", "name": "work", "sessions": "# +
            #"[ { "id": "\#(session.uuidString)", "cwd": "/a" } ] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.workspaces.map(\.id) == [ws])
        #expect(loaded.workspaces[0].sessions.map(\.id) == [session])

        let app = AppStore(persistence: store)
        app.restore(from: loaded)
        app.save()
        let persisted = try #require(persistedSessions().first)
        #expect(persisted["shell"] == nil, "a default-shell session must omit the key, not write one")
        #expect(persisted["cwd"] as? String == "/a")
    }

    @Test func aPoisonedSessionShellDoesNotWipeTheTree() throws {
        // the shell's defense-in-depth lives at SPAWN time, not at load: a nonsense value (a hand edit, a
        // downgrade, the wrong JSON type) must still LOAD, because the alternative — throwing — fails the
        // whole `workspaces` array and costs the user every workspace and session over one broken field.
        let ws = UUID()
        let session = UUID()
        let cases = [#""shell": "  ""#, #""shell": "zsh""#, #""shell": "/bin/zsh\nrm -rf /""#, #""shell": 42"#]
        for bad in cases {
            let json = #"{ "version": 1, "workspaces": [ { "id": "\#(ws.uuidString)", "name": "work", "sessions": "# +
                #"[ { "id": "\#(session.uuidString)", "cwd": "/a", \#(bad) } ] } ] }"#
            try Data(json.utf8).write(to: fileURL)
            let loaded = store.load()
            #expect(loaded.workspaces.map(\.id) == [ws], "\(bad) wiped the tree")
            let restored = try #require(loaded.workspaces.first?.sessions.first, "\(bad) wiped the sessions")
            #expect(restored.id == session)
            #expect(restored.cwd == "/a", "\(bad) must not disturb the fields around it")
        }
    }

    @Test func explicitCollapsedFalseDecodesExpanded() throws {
        // an explicit `collapsed: false` (a hand-edit, or a snapshot from a future build that always writes
        // the field) must decode to expanded, same as an absent key — `!(false ?? false)` == expanded.
        let ws = UUID()
        let session = UUID()
        let json = #"{ "version": 1, "workspaces": [ { "id": "\#(ws.uuidString)", "name": "work", "# +
            #""collapsed": false, "sessions": [ { "id": "\#(session.uuidString)", "cwd": "/a" } ] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.workspaces[0].collapsed == false)

        let app = AppStore(persistence: store)
        app.restore(from: loaded)
        #expect(app.workspaces[0].isExpanded)
    }

    @Test func selectSessionPersistsSelectionToDisk() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let a = try! #require(app.addSession(toWorkspace: work.id, cwd: "/a"))
        let b = try! #require(app.addSession(toWorkspace: work.id, cwd: "/b"))
        // selection saves are debounced; flush via save() so the write lands before reading back.
        app.selectSession(a.id)
        app.save()
        #expect(store.load().selectedSessionID == a.id)
        app.selectSession(b.id)
        app.save()
        #expect(store.load().selectedSessionID == b.id)
    }

    @Test func selectSessionNilDeselectsAndPersists() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let a = try! #require(app.addSession(toWorkspace: work.id, cwd: "/a"))
        // selection saves are debounced; flush via save() so the write lands before reading back.
        app.selectSession(a.id)
        app.save()
        #expect(store.load().selectedSessionID == a.id)
        app.selectSession(nil)
        app.save()
        #expect(app.selectedSessionID == nil)
        #expect(store.load().selectedSessionID == nil)
    }

    @Test func loadMissingFileReturnsDefault() {
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let loaded = store.load()
        #expect(loaded == Snapshot())
        #expect(loaded.workspaces.isEmpty)
        #expect(loaded.selectedSessionID == nil)
    }

    @Test func loadCorruptFileReturnsDefault() throws {
        try Data("{ not valid json ]".utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded == Snapshot())
    }

    @Test func loadVersionMismatchReturnsDefault() throws {
        var future = Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: [])])
        future.version = Snapshot.currentVersion + 1
        let data = try JSONEncoder().encode(future)
        try data.write(to: fileURL)
        let loaded = store.load()
        #expect(loaded == Snapshot())
        #expect(loaded.workspaces.isEmpty)
    }

    @Test func saveCreatesDirectoryWhenMissing() throws {
        let nested = directory.appendingPathComponent("does/not/exist/yet")
        let nestedStore = PersistenceStore(directory: nested)
        let snapshot = Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: [])])
        try nestedStore.save(snapshot)
        #expect(nestedStore.load() == snapshot)
    }

    // MARK: - the pinned restore-command override (session.restore)

    /// A one-session snapshot carrying the given pins, for the arming tests below.
    private func pinnedSnapshot(id: UUID = UUID(), isSplit: Bool = false,
                                pin: String?, splitPin: String? = nil) -> Snapshot {
        Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
            SessionSnapshot(id: id, customName: nil, cwd: "/tmp", isSplit: isSplit,
                            restoreCommand: pin, splitRestoreCommand: splitPin),
        ])])
    }

    @Test func snapshotWrittenBeforeTheOverrideExistedStillDecodesWithNoPin() throws {
        // the format guard: the two keys are OPTIONAL and the snapshot version is unchanged, so a file from
        // a build that never heard of them loads with the tree intact and no pin (= the old behavior).
        let legacy = """
        {"id":"\(UUID().uuidString)","customName":null,"cwd":"/tmp"}
        """
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.restoreCommand == nil)
        #expect(decoded.splitRestoreCommand == nil)
        #expect(decoded.cwd == "/tmp")
    }

    @Test func pinsRoundTripThroughDiskIncludingThePinnedToNothingState() throws {
        let pinned = SessionSnapshot(id: UUID(), customName: nil, cwd: "/tmp", isSplit: true,
                                     restoreCommand: "cd api && npm run dev", splitRestoreCommand: "")
        let original = Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: [pinned])])
        try store.save(original)
        let decoded = store.load()
        #expect(decoded == original)
        // "" survives as "" (pinned to nothing), distinct from a missing key (no pin)
        #expect(decoded.workspaces[0].sessions[0].splitRestoreCommand == "")
        // and an unpinned session omits the key entirely rather than writing null
        let bare = try JSONEncoder().encode(SessionSnapshot(id: UUID(), customName: nil, cwd: "/tmp"))
        #expect(!String(decoding: bare, as: UTF8.self).contains("restoreCommand"))
    }

    @Test func onlyALaunchRestoreArmsThePin() {
        // the key safety property: a mid-process reload (the default) must arm nothing, or a pin would fire
        // as "run this again" without being asked.
        let id = UUID()
        let runtime = AppStore(persistence: store)
        runtime.restore(from: pinnedSnapshot(id: id, pin: "npm run dev"))
        let reloaded = try! #require(runtime.session(withID: id))
        #expect(reloaded.restoreCommand == "npm run dev") // persisted state carried…
        #expect(reloaded.pendingRestoreCommand == nil)    // …but nothing armed

        let bootstrap = AppStore(persistence: store)
        bootstrap.restore(from: pinnedSnapshot(id: id, pin: "npm run dev"), launchRestore: true)
        let armed = try! #require(bootstrap.session(withID: id))
        #expect(armed.pendingRestoreCommand == "npm run dev")
    }

    @Test func aHiddenSplitDropsItsPinAndArmsNothing() {
        // a split hidden at the last quit builds no right surface, so its pin describes a pane that no
        // longer exists — it must not survive to fire on a later manual split.
        let id = UUID()
        let app = AppStore(persistence: store)
        app.restore(from: pinnedSnapshot(id: id, isSplit: false, pin: nil, splitPin: "htop"), launchRestore: true)
        let session = try! #require(app.session(withID: id))
        #expect(session.splitRestoreCommand == nil)
        #expect(session.pendingSplitRestoreCommand == nil)
    }

    @Test func aShownSplitArmsItsOwnPinSeparately() {
        let id = UUID()
        let app = AppStore(persistence: store)
        app.restore(from: pinnedSnapshot(id: id, isSplit: true, pin: "", splitPin: "htop"), launchRestore: true)
        let session = try! #require(app.session(withID: id))
        #expect(session.pendingRestoreCommand == "")       // main pinned to nothing
        #expect(session.pendingSplitRestoreCommand == "htop")
    }

    @Test func takingAPendingOverrideConsumesItOnce() {
        let session = Session(initialCwd: "/tmp")
        session.restoreCommand = "npm run dev"
        session.isSplit = true
        session.splitRestoreCommand = "htop"
        session.armPendingRestoreOverrides()

        #expect(session.takePendingRestoreOverride(pane: .left) == "npm run dev")
        #expect(session.takePendingRestoreOverride(pane: .left) == nil) // a second surface = a plain shell
        #expect(session.takePendingRestoreOverride(pane: .right) == "htop")
        #expect(session.takePendingRestoreOverride(pane: .right) == nil)
        #expect(session.takePendingRestoreOverride(pane: .scratch) == nil) // never restored
        // the persisted pins are untouched, so the next launch fires them again
        #expect(session.restoreCommand == "npm run dev")
        #expect(session.splitRestoreCommand == "htop")
    }

    @Test func clearingPendingOverridesLeavesThePersistedPinsAlone() {
        let session = Session(initialCwd: "/tmp")
        session.restoreCommand = "npm run dev"
        session.armPendingRestoreOverrides()
        session.clearPendingRestoreOverrides()
        #expect(session.pendingRestoreCommand == nil)
        #expect(session.restoreCommand == "npm run dev")
    }

    @Test func setRestoreCommandPersistsImmediatelyAndIsTriState() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let session = try! #require(app.addSession(toWorkspace: work.id, cwd: "/tmp"))
        session.hasSplit = true

        #expect(app.setRestoreCommand("cd api && npm run dev", pane: .left, forSession: session.id))
        // persisted IMMEDIATELY (no debounce): the pin has to survive a SIGKILL before the next launch.
        #expect(store.load().workspaces[0].sessions[0].restoreCommand == "cd api && npm run dev")

        #expect(app.setRestoreCommand("", pane: .right, forSession: session.id))
        #expect(store.load().workspaces[0].sessions[0].splitRestoreCommand == "")

        #expect(app.setRestoreCommand(nil, pane: .left, forSession: session.id))
        #expect(store.load().workspaces[0].sessions[0].restoreCommand == nil)

        // arming is NOT a side effect of the write: a pin set during this run must not execute during it.
        #expect(session.pendingRestoreCommand == nil)
        // nothing to write for an unknown session or the scratch pane
        #expect(!app.setRestoreCommand("x", pane: .left, forSession: UUID()))
        #expect(!app.setRestoreCommand("x", pane: .scratch, forSession: session.id))
    }
}
