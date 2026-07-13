import Foundation
import Testing
@testable import rookCore

/// The Markdown preview panel's host-free half: the store mutators (`session.markdown` / the link click
/// drive these), the `SessionSnapshot` persistence, and the `tree` read-back.
@MainActor
struct MarkdownStoreTests {
    @Test func openSetsThePathAndBumpsTheToken() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/proj")!
        #expect(session.markdownPath == nil)
        let before = session.markdownRefreshToken

        store.openMarkdown("/proj/PLAN.md", forSession: session.id)
        #expect(session.markdownPath == "/proj/PLAN.md")
        #expect(session.markdownRefreshToken == before &+ 1)
    }

    @Test func reopeningTheSamePathStillBumpsTheToken() {
        // by design: an agent keeps rewriting the file it linked, so a second open must re-READ it rather
        // than leave the stale render on screen.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/proj")!
        store.openMarkdown("/proj/PLAN.md", forSession: session.id)
        let after1 = session.markdownRefreshToken

        store.openMarkdown("/proj/PLAN.md", forSession: session.id)
        #expect(session.markdownPath == "/proj/PLAN.md")
        #expect(session.markdownRefreshToken == after1 &+ 1)
    }

    @Test func openRetargetsAnOpenPanel() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/proj")!
        store.openMarkdown("/proj/PLAN.md", forSession: session.id)

        store.openMarkdown("/proj/NOTES.md", forSession: session.id)
        #expect(session.markdownPath == "/proj/NOTES.md")
    }

    @Test func closeClearsThePath() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/proj")!
        store.openMarkdown("/proj/PLAN.md", forSession: session.id)

        store.closeMarkdown(session.id)
        #expect(session.markdownPath == nil)
        store.closeMarkdown(session.id)          // idempotent: closing a closed panel is a clean no-op
        #expect(session.markdownPath == nil)
    }

    @Test func toggleOpensClosesAndSwitchesFiles() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/proj")!

        store.toggleMarkdown(session.id, path: "/proj/PLAN.md")      // closed -> open on the file
        #expect(session.markdownPath == "/proj/PLAN.md")
        store.toggleMarkdown(session.id, path: "/proj/NOTES.md")     // showing another file -> retarget
        #expect(session.markdownPath == "/proj/NOTES.md")
        store.toggleMarkdown(session.id, path: "/proj/NOTES.md")     // showing THIS file -> close
        #expect(session.markdownPath == nil)
    }

    @Test func bareToggleOnlyClosesAnOpenPanel() {
        // the menu/keybind form: no file of its own to offer, so a closed panel stays closed.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/proj")!

        store.toggleMarkdown(session.id)
        #expect(session.markdownPath == nil)
        store.openMarkdown("/proj/PLAN.md", forSession: session.id)
        store.toggleMarkdown(session.id)
        #expect(session.markdownPath == nil)
    }

    @Test func unknownIdIsANoOp() {
        let store = makeStore()
        store.openMarkdown("/proj/PLAN.md", forSession: UUID())
        store.closeMarkdown(UUID())
        store.toggleMarkdown(UUID(), path: "/proj/PLAN.md")
        #expect(store.workspaces.isEmpty)
    }

    @Test func openPanelSurvivesRestore() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/proj")!
        store.openMarkdown("/proj/PLAN.md", forSession: session.id)

        let restored = makeStore()
        restored.restore(from: store.snapshot())
        #expect(restored.workspaces[0].sessions[0].markdownPath == "/proj/PLAN.md")
    }

    @Test func sessionSnapshotRoundTripsMarkdownPath() throws {
        let snapshot = SessionSnapshot(id: UUID(), customName: nil, cwd: "/proj", markdownPath: "/proj/PLAN.md")
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.markdownPath == "/proj/PLAN.md")
    }

    @Test func snapshotWrittenBeforeThePanelExistedDecodesToNil() throws {
        // forward-compat: a `workspaces.json` with no `markdownPath` key must decode (closed panel), not throw.
        let json = #"{"id":"\#(UUID().uuidString)","cwd":"/proj"}"#
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(decoded.markdownPath == nil)
    }

    @Test func controlTreeReportsTheMarkdownPath() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/proj")!
        #expect(store.controlTree().workspaces[0].sessions[0].markdownPath == nil)

        store.openMarkdown("/proj/PLAN.md", forSession: session.id)
        #expect(store.controlTree().workspaces[0].sessions[0].markdownPath == "/proj/PLAN.md")
    }
}
