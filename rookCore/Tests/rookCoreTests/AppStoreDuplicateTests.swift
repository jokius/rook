import Foundation
import Testing
@testable import rookCore

@MainActor
struct AppStoreDuplicateTests {
    @Test func duplicateInsertsFreshShellAfterSourceInSameWorkspace() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a", command: "top", name: "custom"))
        let b = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let dup = try! #require(store.duplicateSession(a.id))
        // lands directly after its source, before b, same workspace
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, dup.id, b.id])
        // ONLY the directory carries over — plain shell, no inherited name/command
        #expect(dup.initialCwd == a.focusedCwd)
        #expect(dup.customName == nil)
        #expect(dup.initialCommand == nil)
        // returns a NEW session and selects it
        #expect(dup.id != a.id)
        #expect(store.selectedSessionID == dup.id)
    }

    @Test func duplicateReturnsNilForUnknownID() {
        let store = makeStore()
        #expect(store.duplicateSession(UUID()) == nil)
    }
}
