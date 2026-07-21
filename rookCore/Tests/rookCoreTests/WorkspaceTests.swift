import Foundation
import Testing
@testable import rookCore

@MainActor
struct WorkspaceTests {
    @Test func unseenCountSumsItsSessions() {
        let a = Session(initialCwd: "/a")
        let b = Session(initialCwd: "/b")
        a.unseenCount = 2
        b.unseenCount = 3
        let workspace = Workspace(name: "work", sessions: [a, b])
        #expect(workspace.unseenCount == 5)
    }

    @Test func unseenCountIsZeroWhenNonePending() {
        let workspace = Workspace(name: "empty", sessions: [Session(initialCwd: "/a")])
        #expect(workspace.unseenCount == 0)
    }

    @Test func rootDefaultsNilAndIsSettable() {
        // the per-workspace start directory: absent by default, holds a path once set.
        var workspace = Workspace(name: "proj", sessions: [])
        #expect(workspace.root == nil)
        workspace.root = "/Users/me/proj"
        #expect(workspace.root == "/Users/me/proj")
    }
}
