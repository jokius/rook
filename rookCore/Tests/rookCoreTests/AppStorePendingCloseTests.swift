import Foundation
import Testing
@testable import rookCore

/// The undo-toast plumbing: a soft close records its grace window on the summary so the toast can draw a
/// countdown, and hover pauses/resumes the finalize timer (navigate away → the close never lands until you
/// leave). Host-free store surface behind the toast in `WindowContentView`.
@MainActor
struct AppStorePendingCloseTests {
    @Test func softCloseRecordsGraceIntervalOnTheSummary() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))

        // a long grace so the timer never fires during the test; the summary must carry that duration so
        // the toast can render a countdown against it.
        #expect(store.softCloseSession(closing.id, grace: 42))
        let summary = try #require(store.pendingCloseSummary)
        #expect(summary.graceInterval == 42)
    }

    @Test func pauseHoldsThePendingCloseThenResumeLetsItFinalize() async throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let survivor = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let surface = SpySurface()
        closing.surface = surface
        store.selectSession(closing.id)

        #expect(store.softCloseSession(closing.id, grace: 0.2))
        let summary = try #require(store.pendingCloseSummary)

        // pause synchronously — before the grace timer (0.2s) can fire — so it cancels the scheduled finalize.
        store.pausePendingCloseFinalization(summary.id)

        // wait well past the grace window: a PAUSED close must not finalize (cancelled timer never fires).
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(store.pendingCloseSummary != nil, "a paused close must stay pending past its grace")
        #expect(surface.teardownCount == 0, "a paused close must not tear the surface down")

        // resume reschedules the full grace; the close now finalizes on its own.
        store.resumePendingCloseFinalization(summary.id)
        for _ in 0..<200 {
            if store.pendingCloseSummary == nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(store.pendingCloseSummary == nil, "resume must let the close finalize")
        #expect(surface.teardownCount == 1, "finalize tears the surface down")
        _ = survivor
    }
}
