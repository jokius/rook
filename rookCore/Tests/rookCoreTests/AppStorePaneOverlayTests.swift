import Foundation
import Testing
@testable import rookCore

/// The pane-scoped overlay model: the store's open/close/record arms, the lifecycle hooks that follow a pane
/// as it is hidden, torn down, or promoted, and the `Session` predicates every cover/zoom/focus decision
/// derives from. All host-free — the rendering half is verified by eye.
@MainActor
struct AppStorePaneOverlayTests {
    private func splitSession() -> (AppStore, Session) {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.toggleSplit(session.id) // shown split: both panes render, so both accept an overlay
        return (store, session)
    }

    // MARK: - open / close / result

    @Test func openPaneOverlayFillsThatSlotAlone() {
        let (store, session) = splitSession()
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "htop") == nil)
        #expect(session.paneOverlay(.left)?.command == "htop")
        #expect(session.paneOverlay(.right) == nil)
        #expect(session.openPaneOverlays == [.left])
        // the session-wide overlay is a separate slot: both kinds can be up at once.
        #expect(session.overlayActive == false)
    }

    @Test func bothPanesCanCarryTheirOwnOverlayAtOnce() {
        let (store, session) = splitSession()
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "a", backgroundColor: "#112233") == nil)
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "b") == nil)
        #expect(session.openPaneOverlays == [.left, .right])
        // per-overlay fields, so two open at once never share a color.
        #expect(session.paneOverlay(.left)?.backgroundColor == "#112233")
        #expect(session.paneOverlay(.right)?.backgroundColor == nil)
    }

    @Test func openPaneOverlayRejectsAnOccupiedSlot() {
        let (store, session) = splitSession()
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "a") == nil)
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "b") == .alreadyOpen)
        #expect(session.paneOverlay(.left)?.command == "a") // the first one is untouched
    }

    /// An unrendered pane never gets a nonzero backing size, so its surface would never be created and the
    /// slot would sit open with no program — `session.overlay.result --pane` would answer "still running"
    /// forever. Reject at request time instead of opening a dead overlay.
    @Test func openPaneOverlayRejectsAPaneTheDeckDoesNotLayOut() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "a") == .paneNotVisible)
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "a") == nil) // the shown one is fine
    }

    @Test func openPaneOverlayRejectsAnUnknownSession() {
        let store = makeStore()
        #expect(store.openPaneOverlay(UUID(), pane: .left, command: "a") == .unknownSession)
    }

    /// The exit code SURVIVES the close so `session.overlay.result --pane` can report it, and is cleared
    /// only by the next open on that pane.
    @Test func closeKeepsTheExitCodeAndTheNextOpenClearsIt() {
        let (store, session) = splitSession()
        _ = store.openPaneOverlay(session.id, pane: .left, command: "a")
        let surface = SpySurface()
        session.setPaneOverlaySurface(surface, pane: .left)

        store.recordPaneOverlayExit(session.id, pane: .left, code: 7)
        #expect(store.closePaneOverlay(session.id, pane: .left) == true)
        #expect(session.paneOverlay(.left) == nil)
        #expect(session.paneOverlaySurface(.left) == nil)
        #expect(surface.teardownCount == 1)
        #expect(session.paneOverlayExitCode(.left) == 7)

        _ = store.openPaneOverlay(session.id, pane: .left, command: "b")
        #expect(session.paneOverlayExitCode(.left) == nil)
    }

    @Test func closePaneOverlayIsANoOpWithNoneOpen() {
        let (store, session) = splitSession()
        #expect(store.closePaneOverlay(session.id, pane: .right) == false)
    }

    /// `teardownPaneOverlay` is the PANE-IS-GONE form: unlike `closePaneOverlay` it drops the exit code too,
    /// since no pane survives to be asked for it.
    @Test func teardownAlsoDropsTheExitCode() {
        let (store, session) = splitSession()
        _ = store.openPaneOverlay(session.id, pane: .left, command: "a")
        store.recordPaneOverlayExit(session.id, pane: .left, code: 3)
        session.teardownPaneOverlay(.left)
        #expect(session.paneOverlay(.left) == nil)
        #expect(session.paneOverlayExitCode(.left) == nil)
    }

    // MARK: - the pane overlays follow their panes

    @Test func closingTheSplitTearsDownTheRightPaneOverlay() {
        let (store, session) = splitSession()
        _ = store.openPaneOverlay(session.id, pane: .left, command: "keep")
        _ = store.openPaneOverlay(session.id, pane: .right, command: "gone")
        let right = SpySurface()
        session.setPaneOverlaySurface(right, pane: .right)

        store.closeSplit(session.id)
        #expect(session.paneOverlay(.right) == nil)
        #expect(right.teardownCount == 1)
        #expect(session.paneOverlay(.left)?.command == "keep") // the surviving pane keeps its own
    }

    /// The survivor's overlay MOVES into the left slot with its surface and exit code, so
    /// `session.overlay.result --pane left` still answers after the promotion.
    @Test func promotingTheSplitSurvivorMovesItsOverlayLeft() {
        let (store, session) = splitSession()
        session.surface = SpySurface(paneToken: "primary")
        session.splitSurface = SpySurface(paneToken: "helper")
        _ = store.openPaneOverlay(session.id, pane: .left, command: "dies")
        _ = store.openPaneOverlay(session.id, pane: .right, command: "survives")
        let leftOverlay = SpySurface()
        let rightOverlay = SpySurface()
        session.setPaneOverlaySurface(leftOverlay, pane: .left)
        session.setPaneOverlaySurface(rightOverlay, pane: .right)
        store.recordPaneOverlayExit(session.id, pane: .right, code: 5)

        store.closePrimaryPane(session.id)

        #expect(leftOverlay.teardownCount == 1) // the exiting pane's overlay dies with it
        #expect(rightOverlay.teardownCount == 0) // the survivor's is MOVED, never rebuilt
        #expect(session.paneOverlay(.left)?.command == "survives")
        #expect(session.paneOverlaySurface(.left) === rightOverlay)
        #expect(session.paneOverlayExitCode(.left) == 5)
        #expect(session.paneOverlay(.right) == nil)
        #expect(session.paneOverlaySurface(.right) == nil)
    }

    /// A moved surface must re-resolve its own pane from slot occupancy, or its exit/status callbacks would
    /// fire on the slot it was BUILT for and close nothing.
    @Test func paneOverlayRoleReadsTheSlotTheSurfaceOccupiesNow() {
        let (store, session) = splitSession()
        _ = store.openPaneOverlay(session.id, pane: .right, command: "a")
        let surface = SpySurface()
        session.setPaneOverlaySurface(surface, pane: .right)
        #expect(session.paneOverlayRole(of: surface) == .right)

        session.setPaneOverlay(nil, pane: .left)
        session.promotePaneOverlay()
        #expect(session.paneOverlayRole(of: surface) == .left)
        #expect(session.paneOverlayRole(of: SpySurface()) == nil)
    }

    // MARK: - retiring a stranded slot

    /// The slot is open, the pane stopped being laid out, and no terminal was ever created — nothing would
    /// ever close it, so `--block` would hang on it forever. Retire instead of describing the bad state.
    @Test func hidingTheSplitRetiresAnUnrealizedOverlayOnTheHiddenPane() {
        let (store, session) = splitSession()
        _ = store.openPaneOverlay(session.id, pane: .right, command: "a")
        session.setPaneOverlaySurface(SpySurface(isRealized: false), pane: .right)
        session.splitFocused = false

        store.toggleSplit(session.id) // hide the split: only the focused (left) pane renders now
        #expect(session.paneOverlay(.right) == nil)
    }

    /// A REALIZED overlay is left alone: unmounting its surface keeps the program running, and a re-show
    /// remounts it.
    @Test func hidingTheSplitLeavesARealizedOverlayRunning() {
        let (store, session) = splitSession()
        _ = store.openPaneOverlay(session.id, pane: .right, command: "a")
        session.setPaneOverlaySurface(SpySurface(isRealized: true), pane: .right)
        session.splitFocused = false

        store.toggleSplit(session.id)
        #expect(session.paneOverlay(.right)?.command == "a")
    }

    /// The pane the deck still lays out keeps its slot even when the surface has not realized yet — the
    /// host is there, the surface is simply a beat behind.
    @Test func aRenderedPaneKeepsItsUnrealizedOverlay() {
        let (store, session) = splitSession()
        _ = store.openPaneOverlay(session.id, pane: .left, command: "a")
        session.setPaneOverlaySurface(SpySurface(isRealized: false), pane: .left)
        session.dropUnrealizedPaneOverlays()
        #expect(session.paneOverlay(.left)?.command == "a")
    }

    // MARK: - tree read-back

    @Test func controlTreeReportsTheCoveredPanes() {
        let (store, session) = splitSession()
        #expect(store.controlTree().workspaces[0].sessions[0].paneOverlays == nil) // omitted when neither
        _ = store.openPaneOverlay(session.id, pane: .right, command: "a")
        #expect(store.controlTree().workspaces[0].sessions[0].paneOverlays == ["right"])
        _ = store.openPaneOverlay(session.id, pane: .left, command: "b")
        // ordered left then right, whatever order they were opened in.
        #expect(store.controlTree().workspaces[0].sessions[0].paneOverlays == ["left", "right"])
    }
}
