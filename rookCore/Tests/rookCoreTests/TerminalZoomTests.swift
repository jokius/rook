import Foundation
import Testing
@testable import rookCore

@MainActor
struct TerminalZoomTests {
    @Test func resolveTargetPrioritizesQuickThenSessionCoversThenFocusedPane() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        #expect(TerminalZoomController.resolveTarget(store: store, quickTerminalVisible: true) == .quick)
        #expect(TerminalZoomController.resolveTarget(store: store, quickTerminalVisible: false) == .session(session.id, .primary))

        // `splitFocused` alone describes no pane: with neither a shown split nor a split surface the focused
        // pane is still the primary, matching `rendersPane`/`focusedOverlayPane` and `.split`'s isAvailable.
        session.splitFocused = true
        #expect(TerminalZoomController.resolveTarget(store: store, quickTerminalVisible: false) == .session(session.id, .primary))

        store.toggleSplit(session.id)
        session.splitSurface = SpySurface()
        #expect(TerminalZoomController.resolveTarget(store: store, quickTerminalVisible: false) == .session(session.id, .split))

        session.scratchActive = true
        #expect(TerminalZoomController.resolveTarget(store: store, quickTerminalVisible: false) == .session(session.id, .scratch))

        session.overlayActive = true
        #expect(TerminalZoomController.resolveTarget(store: store, quickTerminalVisible: false) == .session(session.id, .overlay))
    }

    @Test func targetValidityTracksQuickVisibilityAndSessionLifetime() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        #expect(TerminalZoomController.isTargetValid(.quick, in: store, quickTerminalVisible: true))
        #expect(!TerminalZoomController.isTargetValid(.quick, in: store, quickTerminalVisible: false))
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .primary), in: store, quickTerminalVisible: false))

        store.closeSession(session.id)
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .primary), in: store, quickTerminalVisible: false))
    }

    @Test func splitTargetStaysValidWhenHiddenAndClearsWhenPromotedOrClosed() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        store.toggleSplit(session.id)
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .split), in: store, quickTerminalVisible: false))

        store.toggleSplit(session.id)
        #expect(session.isSplit == false)
        #expect(session.hasSplit == true)
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .split), in: store, quickTerminalVisible: false))

        // the primary exits: the survivor is PROMOTED into the main slot, so no right pane exists
        // anymore — a zoom on the split target must end, not keep covering the promoted main pane.
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        store.closePrimaryPane(session.id)
        #expect(session.hasSplit == false)
        #expect(session.splitSurface == nil)
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .split), in: store, quickTerminalVisible: false))

        // closing a live split clears the target the ordinary way too.
        store.toggleSplit(session.id)
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .split), in: store, quickTerminalVisible: false))
        store.closeSplit(session.id)
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .split), in: store, quickTerminalVisible: false))
    }

    @Test func primaryTargetStaysValidWhenPrimaryExitsAndSplitIsPromoted() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        #expect(TerminalZoomController.isTargetValid(.session(session.id, .primary), in: store, quickTerminalVisible: false))

        let survivor = SpySurface()
        session.surface = SpySurface()
        session.splitSurface = survivor
        session.isSplit = true
        session.hasSplit = true
        store.closePrimaryPane(session.id)

        // the survivor MOVES into the primary slot: the primary target keeps pointing at the live
        // shell (now the survivor), and the split target dies with the vacated right pane.
        #expect(session.surface === survivor)
        #expect(session.splitSurface == nil)
        #expect(session.splitFocused == false)
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .primary), in: store, quickTerminalVisible: false))
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .split), in: store, quickTerminalVisible: false))
    }

    @Test func scratchAndOverlayTargetsFollowActiveFlags() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        store.toggleScratch(session.id)
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .scratch), in: store, quickTerminalVisible: false))
        store.toggleScratch(session.id)
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .scratch), in: store, quickTerminalVisible: false))
        session.scratchSurface = SpySurface()
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .scratch), in: store, quickTerminalVisible: false))
        store.closeScratch(session.id)
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .scratch), in: store, quickTerminalVisible: false))

        #expect(store.openOverlay(session.id, command: "top"))
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .overlay), in: store, quickTerminalVisible: false))
        #expect(store.closeOverlay(session.id))
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .overlay), in: store, quickTerminalVisible: false))
    }

    @Test func surfaceIDsRoundTripControlNames() throws {
        let sessionID = try #require(UUID(uuidString: "5E5B1C5B-75C5-49E6-8806-2C61D8D6BBA9"))
        let surfaceID = TerminalSurfaceID(sessionID: sessionID, surface: .split)

        #expect(surfaceID.rawValue == "surface:5E5B1C5B-75C5-49E6-8806-2C61D8D6BBA9:right")
        #expect(TerminalSurfaceID(rawValue: surfaceID.rawValue) == surfaceID)
        #expect(TerminalSurfaceID(rawValue: "surface:\(sessionID.uuidString):split") == surfaceID)
        #expect(TerminalSurfaceID(rawValue: "session:\(sessionID.uuidString):right") == nil)
    }

    @Test func setModeIsIdempotentAndTargeted() {
        let controller = TerminalZoomController()
        let sessionID = UUID()
        let left = TerminalZoomTarget.session(sessionID, .primary)
        let right = TerminalZoomTarget.session(sessionID, .split)

        controller.set(.on, target: left)
        #expect(controller.target == left)
        controller.set(.on, target: left)
        #expect(controller.target == left)
        controller.set(.off, target: right)
        #expect(controller.target == left)
        controller.set(.toggle, target: left)
        #expect(controller.target == nil)
        controller.set(.toggle, target: right)
        #expect(controller.target == right)
        controller.set(.off, target: nil)
        #expect(controller.target == nil)
    }

    // MARK: - pane-overlay surfaces

    @Test func paneOverlaySurfacesAreAvailableOnlyWhileTheirSlotIsFilled() {
        let session = Session(initialCwd: "/a")
        session.isSplit = true
        #expect(TerminalZoomSurface.overlayLeft.isAvailable(in: session) == false)
        #expect(TerminalZoomSurface.overlayRight.isAvailable(in: session) == false)

        session.setPaneOverlay(PaneOverlay(command: "a"), pane: .right)
        #expect(TerminalZoomSurface.overlayRight.isAvailable(in: session) == true)
        #expect(TerminalZoomSurface.overlayLeft.isAvailable(in: session) == false)
    }

    /// `resolveTarget` takes the FIRST active case, so exactly one may ever be active. A pane and its own
    /// overlay are separated by that pane's slot alone — widening one without narrowing the other silently
    /// picks the wrong zoom target.
    @Test func exactlyOneSurfaceIsActiveWithAPaneOverlayUp() {
        let session = Session(initialCwd: "/a")
        session.isSplit = true
        #expect(TerminalZoomSurface.allCases.filter { $0.isActive(in: session) } == [.primary])

        session.setPaneOverlay(PaneOverlay(command: "a"), pane: .left)
        #expect(TerminalZoomSurface.allCases.filter { $0.isActive(in: session) } == [.overlayLeft])

        session.splitFocused = true
        // focus moved to the uncovered right pane; the left overlay is still up but no longer in front.
        #expect(TerminalZoomSurface.allCases.filter { $0.isActive(in: session) } == [.split])

        // a session-wide cover outranks both panes and their overlays.
        session.overlayActive = true
        #expect(TerminalZoomSurface.allCases.filter { $0.isActive(in: session) } == [.overlay])
    }

    /// Visibility is the LAYOUT question, so BOTH sides of a shown split report visible — but a pane
    /// renders at opacity 0 under its own overlay, so the overlay takes that pane's visibility.
    @Test func aPaneOverlayTakesItsPanesVisibility() {
        let session = Session(initialCwd: "/a")
        session.isSplit = true
        #expect(TerminalZoomSurface.allCases.filter { $0.isVisible(in: session) } == [.primary, .split])

        session.setPaneOverlay(PaneOverlay(command: "a"), pane: .left)
        #expect(TerminalZoomSurface.allCases.filter { $0.isVisible(in: session) } == [.split, .overlayLeft])

        // a session-wide cover hides both panes AND their overlays.
        session.scratchActive = true
        #expect(TerminalZoomSurface.allCases.filter { $0.isVisible(in: session) } == [.scratch])
    }

    @Test func paneOverlaySurfacesRoundTripTheirControlNames() {
        #expect(TerminalZoomSurface(controlName: "overlay-left") == .overlayLeft)
        #expect(TerminalZoomSurface(controlName: "overlay-right") == .overlayRight)
        #expect(TerminalZoomSurface.overlayLeft.rawValue == "overlay-left")
        #expect(OverlayPane.left.zoomSurface == .overlayLeft)
        #expect(OverlayPane.right.paneZoomSurface == .split)
    }
}
