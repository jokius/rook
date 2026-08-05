import Foundation
import Testing
@testable import rookCore

/// The store's HUD slot lifecycle and the `tree` read-back it feeds. Upstream split these across
/// `AppStorePaneTests` (lifecycle) and its own file (read-back); both live here so the pane suite stays
/// inside the file-size budget and every HUD store rule reads in one place.
@MainActor
struct AppStoreHudTests {

    // MARK: - slot lifecycle

    @Test func openHudOccupiesTheSlotAndMarksItAHud() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let spec = HudSpec(message: "gathering options", detail: "scanning", backgroundColor: "#101820")
        #expect(store.openHud(session.id, command: "hud.sh", spec: spec, file: "/tmp/h",
                              size: HudPanelSize(widthPercent: 30, heightPercent: 9)) == true)
        #expect(session.overlayActive == true)
        #expect(session.hudActive == true)
        #expect(session.overlayCommand == "hud.sh")
        #expect(session.hudSpec == spec)
        #expect(session.hudFile == "/tmp/h")
        #expect(session.overlaySizePercent == 30)
        // the height arrives measured and is stored as given: only the width takes the caller-facing clamp
        #expect(session.hudHeightPercent == 9)
        // the spec's color reaches the slot the factory reads, and a HUD is never a PROGRAM overlay.
        #expect(session.overlayBackgroundColor == "#101820")
        #expect(session.fullOverlayActive == false)
        #expect(session.programOverlayActive == false)
        // a HUD's own clamp, not the overlay's 1...100: 100 would cover the session the message is about,
        // which is the invariant `overlay.resize --full` is refused for.
        store.closeHud(session.id)
        store.openHud(session.id, command: "hud.sh", spec: spec, file: "/tmp/h",
                      size: HudPanelSize(widthPercent: 400, heightPercent: 9))
        #expect(session.overlaySizePercent == HudLayout.maxSizePercent)
        store.closeHud(session.id)
        store.openHud(session.id, command: "hud.sh", spec: spec, file: "/tmp/h",
                      size: HudPanelSize(widthPercent: 1, heightPercent: 9))
        #expect(session.overlaySizePercent == HudLayout.minSizePercent)
    }

    @Test func updateHudRewritesInPlaceWithoutRespawning() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one"), file: "/tmp/a",
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        let surface = SpySurface()
        session.overlaySurface = surface
        let generation = session.overlaySlotGeneration
        let next = HudSpec(message: "two", detail: "still working", spinner: .braille, position: .top)
        #expect(store.updateHud(session.id, spec: next,
                                size: HudPanelSize(widthPercent: 44, heightPercent: 15)) == true)
        #expect(session.hudSpec == next)
        // an update cannot move the file: the running helper opened the path `openHud` gave it.
        #expect(session.hudFile == "/tmp/a")
        #expect(session.overlaySizePercent == 44)
        // a longer message is a taller panel, so both axes move with the text
        #expect(session.hudHeightPercent == 15)
        // the helper re-reads the file, so nothing re-spawns: same surface, same view identity.
        #expect(surface.teardownCount == 0)
        #expect(session.overlaySurface === surface)
        #expect(session.overlaySlotGeneration == generation)
        // an update takes the HUD's clamp too, at both ends, so no resize path can grow it into a cover.
        #expect(store.updateHud(session.id, spec: next,
                                size: HudPanelSize(widthPercent: 0, heightPercent: 9)) == true)
        #expect(session.overlaySizePercent == HudLayout.minSizePercent)
        #expect(store.updateHud(session.id, spec: next,
                                size: HudPanelSize(widthPercent: 100, heightPercent: 9)) == true)
        #expect(session.overlaySizePercent == HudLayout.maxSizePercent)
    }

    @Test func resizingAHudLeavesItsMeasuredHeightAlone() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one"), file: "/tmp/a",
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))

        #expect(store.resizeOverlay(session.id, sizePercent: 60) == true)

        #expect(session.overlaySizePercent == 60)
        // the text wraps at maxColumns rather than at the panel, so a wider panel needs no more rows
        #expect(session.hudHeightPercent == 9)
    }

    @Test func updateHudRefusesWithoutAHud() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let spec = HudSpec(message: "hello")
        let size = HudPanelSize(widthPercent: 20, heightPercent: 9)
        #expect(store.updateHud(session.id, spec: spec, size: size) == false)
        // a caller's program in the slot is not a HUD's to rewrite.
        store.openOverlay(session.id, command: "htop", sizePercent: 60)
        #expect(store.updateHud(session.id, spec: spec, size: size) == false)
        #expect(session.hudSpec == nil)
        #expect(session.overlaySizePercent == 60)
    }

    @Test func updateHudKeepsTheColorTheSurfaceWasCreatedWith() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one", backgroundColor: "#101820"),
                      file: "/tmp/a", size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        // the CLI's update carries no color, and the panel still paints the one it was created with
        #expect(store.updateHud(session.id, spec: HudSpec(message: "two"),
                                size: HudPanelSize(widthPercent: 30, heightPercent: 9)) == true)
        #expect(session.hudSpec?.backgroundColor == "#101820")
        #expect(session.overlayBackgroundColor == "#101820")
        // nor may a color the factory will never read reach the stored spec
        let recolor = HudSpec(message: "three", backgroundColor: "#ff0000")
        #expect(store.updateHud(session.id, spec: recolor,
                                size: HudPanelSize(widthPercent: 30, heightPercent: 9)) == true)
        #expect(session.hudSpec?.backgroundColor == "#101820")
        #expect(session.overlayBackgroundColor == "#101820")
        #expect(session.hudSpec?.message == "three")
    }

    /// Every store-only HUD teardown, none of which runs a surface teardown: a HUD closed before its panel
    /// realized would otherwise leave its message text in `/tmp` forever.
    @Test(arguments: HudTeardownPath.allCases)
    func storeTeardownRemovesAnUnrealizedHudBodyFile(_ path: HudTeardownPath) throws {
        let store = makeStore()
        _ = store.addWorkspace(name: "keep") // removeWorkspace keeps the last workspace
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let file = try Self.makeBodyFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        #expect(store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "gathering options"),
                              file: file, size: HudPanelSize(widthPercent: 20, heightPercent: 9)) == true)
        #expect(session.overlaySurface == nil)

        switch path {
        case .overlayClose: #expect(store.closeOverlay(session.id) == true)
        case .hudClose: #expect(store.closeHud(session.id) == true)
        case .sessionClose: store.closeSession(session.id)
        case .workspaceRemove: store.removeWorkspace(ws.id)
        case .pendingFinalize:
            #expect(store.softCloseSession(session.id) == true)
            store.finalizeAllPendingCloses()
        }

        #expect(!FileManager.default.fileExists(atPath: file))
    }

    enum HudTeardownPath: CaseIterable, Sendable {
        case overlayClose, hudClose, sessionClose, workspaceRemove, pendingFinalize
    }

    private static func makeBodyFile() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rook-hud-test-\(UUID().uuidString).txt")
        try Data("20 4 0 1\ngathering options".utf8).write(to: url)
        return url.path
    }

    @Test func closeHudTearsDownAndClearsTheSlot() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one"), file: "/tmp/a",
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        let surface = SpySurface()
        session.overlaySurface = surface
        #expect(store.closeHud(session.id) == true)
        #expect(surface.teardownCount == 1)
        #expect(session.overlayActive == false)
        #expect(session.hudActive == false)
        #expect(session.hudSpec == nil)
        #expect(session.hudFile == nil)
        #expect(session.hudHeightPercent == nil)
        #expect(session.overlaySizePercent == nil)
        #expect(store.closeHud(session.id) == false)
    }

    @Test func closeHudRefusesAProgramOverlay() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        store.openOverlay(session.id, command: "htop", sizePercent: 60)
        #expect(store.closeHud(session.id) == false)
        #expect(session.overlayActive == true)
        #expect(session.overlayCommand == "htop")
    }

    @Test func closeOverlayClearsHudState() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one"), file: "/tmp/a",
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        // the courtesy path (`session.overlay.close`, ⌘W) clears the HUD as thoroughly as `closeHud` does.
        #expect(store.closeOverlay(session.id) == true)
        #expect(session.hudSpec == nil)
        #expect(session.hudFile == nil)
        #expect(session.hudActive == false)
    }

    @Test func secondOpenHudReplacesTheFirst() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one"), file: "/tmp/a",
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        let first = SpySurface()
        session.overlaySurface = first
        let generation = session.overlaySlotGeneration
        let next = HudSpec(message: "two", position: .bottom)
        #expect(store.openHud(session.id, command: "hud.sh", spec: next, file: "/tmp/b",
                              size: HudPanelSize(widthPercent: 35, heightPercent: 9)) == true)
        #expect(session.hudSpec == next)
        #expect(session.hudFile == "/tmp/b")
        #expect(session.overlaySizePercent == 35)
        // an open is a fresh panel: the old surface is gone and the identity moves, so the deck re-mounts.
        #expect(first.teardownCount == 1)
        #expect(session.overlaySurface == nil)
        #expect(session.overlaySlotGeneration > generation)
    }

    @Test func openOverlayReplacesAHudButRefusesAProgram() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one"), file: "/tmp/a",
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        let hud = SpySurface()
        session.overlaySurface = hud
        let generation = session.overlaySlotGeneration
        #expect(store.openOverlay(session.id, command: "htop") == true)
        #expect(session.hudSpec == nil)
        #expect(session.hudFile == nil)
        #expect(session.hudActive == false)
        #expect(session.overlayCommand == "htop")
        #expect(session.fullOverlayActive == true)
        // the HUD's surface is torn down and the identity moves, so the program actually mounts.
        #expect(hud.teardownCount == 1)
        #expect(session.overlaySurface == nil)
        #expect(session.overlaySlotGeneration > generation)
        // a RUNNING program still owns the slot against everything.
        #expect(store.openOverlay(session.id, command: "other") == false)
        #expect(store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "x"), file: "/tmp/c",
                              size: HudPanelSize(widthPercent: 20, heightPercent: 9)) == false)
        #expect(session.overlayCommand == "htop")
        #expect(session.hudSpec == nil)
    }

    @Test func overlaySlotGenerationTracksOpensOnly() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        #expect(session.overlaySlotGeneration == 0)
        store.openOverlay(session.id, command: "htop", sizePercent: 60)
        #expect(session.overlaySlotGeneration == 1)
        // a resize keeps the same surface mounted, so the identity must hold still.
        store.resizeOverlay(session.id, sizePercent: 30)
        #expect(session.overlaySlotGeneration == 1)
        // a refused open must not move it either, or the deck re-mounts the running program.
        #expect(store.openOverlay(session.id, command: "other") == false)
        #expect(session.overlaySlotGeneration == 1)
        store.closeOverlay(session.id)
        #expect(session.overlaySlotGeneration == 1)
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one"), file: "/tmp/a",
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        #expect(session.overlaySlotGeneration == 2)
    }

    @Test func hudCommandsRefuseAnUnknownSession() {
        let store = makeStore()
        #expect(store.openHud(UUID(), command: "hud.sh", spec: HudSpec(message: "x"), file: "/tmp/a",
                              size: HudPanelSize(widthPercent: 20, heightPercent: 9)) == false)
        #expect(store.updateHud(UUID(), spec: HudSpec(message: "x"),
                                size: HudPanelSize(widthPercent: 20, heightPercent: 9)) == false)
        #expect(store.closeHud(UUID()) == false)
    }

    // MARK: - tree read-back

    @Test func controlTreeReportsHudWithEveryField() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        let spec = HudSpec(message: "gathering options", detail: "scanning 400 files", spinner: .braille,
                           backgroundColor: "#2a1a3a", sizePercent: 35, position: .top)
        store.openHud(session.id, command: "hud.sh", spec: spec, file: "/tmp/hud", size: HudPanelSize(widthPercent: 35, heightPercent: 12))

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.hud == ControlHudNode(message: "gathering options", detail: "scanning 400 files",
                                           spinner: "braille", backgroundColor: "#2a1a3a", sizePercent: 35,
                                           heightPercent: 12, position: "top"))
    }

    @Test func controlTreeReportsTheEffectiveHudPositionAndSize() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        // the caller set neither, so the read-back still names the default and the app's own measurement.
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 22, heightPercent: 9))

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.hud?.position == "center")
        #expect(node.hud?.sizePercent == 22)
        #expect(node.hud?.heightPercent == 9)
        #expect(node.hud?.spinner == HudSpinner.noneName)
        #expect(node.hud?.detail == nil)
        #expect(node.hud?.backgroundColor == nil)
    }

    @Test func controlTreeKeepsTheHudColorAcrossAnUpdate() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one", backgroundColor: "#2a1a3a"),
                      file: "/tmp/hud", size: HudPanelSize(widthPercent: 30, heightPercent: 9))

        store.updateHud(session.id, spec: HudSpec(message: "two"), size: HudPanelSize(widthPercent: 30, heightPercent: 9))
        var node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.hud?.backgroundColor == "#2a1a3a", "the color the panel still paints must survive")

        store.updateHud(session.id, spec: HudSpec(message: "three", backgroundColor: "#ff0000"),
                        size: HudPanelSize(widthPercent: 30, heightPercent: 9))
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.hud?.backgroundColor == "#2a1a3a", "a color the surface will never read must not be reported")
        #expect(node.hud?.message == "three")
    }

    @Test func controlTreeOmitsHudWithoutOne() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))

        #expect(try #require(store.controlTree().workspaces[0].sessions.first).hud == nil)

        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        store.closeHud(session.id)

        #expect(try #require(store.controlTree().workspaces[0].sessions.first).hud == nil)
    }

    @Test func controlTreeNeverReportsAHudAsAProgramOverlay() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))

        let withHud = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(!withHud.overlay)
        #expect(withHud.overlaySizePercent == nil)

        store.openOverlay(session.id, command: "htop", sizePercent: 70)
        let withProgram = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(withProgram.overlay)
        #expect(withProgram.overlaySizePercent == 70)
        #expect(withProgram.hud == nil)
    }
}
