import Foundation
import Testing
@testable import rookCore

/// `session.new` create-flag behavior — `--no-select` background creation (upstream bdc3684) and `--wait`
/// holding a `--command` session open after its command exits (upstream 8220978, issue #254). Split out of
/// `AppStoreTests` to keep that file under the test-file size cap; uses the shared `makeStore()` fixture.
@MainActor
struct AppStoreSessionCreateTests {
    @Test func addSessionCarriesCommandWait() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let held = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", command: "make test", wait: true))
        #expect(held.commandWait == true)
        // default is false — a command session closes when its command exits.
        let plain = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", command: "make test"))
        #expect(plain.commandWait == false)
    }

    @Test func addSessionWithoutSelectLeavesSelectionUntouched() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        #expect(store.selectedSessionID == first.id)
        // a background add (control `session.new --no-select`) appends the session but keeps the current
        // selection and recency, so `active` still points at the first session.
        let background = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/b", select: false))
        #expect(store.workspaces[0].sessions.map(\.id) == [first.id, background.id])
        #expect(store.selectedSessionID == first.id)
        #expect(store.activeSession?.id == first.id)
    }

    @Test func commandWaitRoundTripsThroughSnapshot() {
        // a held --command session persists the flag so a restored session that re-runs its command holds
        // again, keeping the held/closed behavior consistent across restart (issue #254).
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let held = store.addSession(toWorkspace: ws.id, cwd: "/a", command: "make test", wait: true)!
        #expect(held.commandWait == true)
        // a non-holding command session writes false -> nil so the key stays out of the JSON.
        let plain = store.addSession(toWorkspace: ws.id, cwd: "/b", command: "make test")!
        #expect(plain.commandWait == false)
        let snap = store.snapshot()
        #expect(snap.workspaces[0].sessions[0].commandWait == true)
        #expect(snap.workspaces[0].sessions[1].commandWait == nil) // false -> nil write mapping
        // restore: the held session comes back holding (true), the non-holding one decodes nil -> false.
        let restored = makeStore()
        restored.restore(from: snap)
        #expect(restored.workspaces[0].sessions[0].commandWait == true)
        #expect(restored.workspaces[0].sessions[1].commandWait == false) // nil -> false restore mapping
    }
}
