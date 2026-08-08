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
        // Only the directory (and the shell, covered below) carries over — no inherited name/command
        #expect(dup.initialCwd == a.focusedCwd)
        #expect(dup.customName == nil)
        #expect(dup.initialCommand == nil)
        // returns a NEW session and selects it
        #expect(dup.id != a.id)
        #expect(store.selectedSessionID == dup.id)
    }

    /// A duplicate is the same session again, so it must come up in the SAME shell — duplicating a fish
    /// session into a zsh one is the divergence the whole feature exists to close, and it would be
    /// invisible until the shell behaved differently.
    @Test func duplicateInheritsTheSourceSessionsShell() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let source = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a", shell: "/opt/homebrew/bin/fish"))
        let dup = try! #require(store.duplicateSession(source.id))
        #expect(dup.shell == "/opt/homebrew/bin/fish")
    }

    /// The mirror case: a session on the app's default shell duplicates into one that names no shell at
    /// all, rather than freezing today's default into the new session's persisted state.
    @Test func duplicateOfADefaultShellSessionNamesNoShell() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let source = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let dup = try! #require(store.duplicateSession(source.id))
        #expect(dup.shell == nil)
    }

    @Test func duplicateReturnsNilForUnknownID() {
        let store = makeStore()
        #expect(store.duplicateSession(UUID()) == nil)
    }
}
