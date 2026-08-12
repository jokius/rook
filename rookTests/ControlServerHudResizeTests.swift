import rookCore
import XCTest
@testable import rook

/// The two `session.overlay.resize` arms that exist only app-side: the `--full` refusal a HUD answers, and
/// the rollback that puts the previous width back when the body write fails. Neither can be reached from
/// `rookCore` — the dispatcher hands `sizePercent` straight to the `ControlActions` witness, and the arm's
/// two decisions read a LIVE session through `ControlServer.writeHudBody` / `paneMetrics` (NSFont cell
/// metrics and laid-out pane geometry), which are app-target code. This is the `ControlServer` fixture the
/// control-api rule recorded as missing.
///
/// The fixture is deliberately narrow, because a `ControlServer` transitively pulls in the whole app graph:
/// - `WindowLibrary` is rooted in a throwaway directory, so the user's real `windows.json` is untouched and
///   `bootstrap()` seeds exactly one window with one workspace and one session.
/// - The server is NEVER `start()`ed on the DEFAULT socket path. The ownership lock keeps it from displacing
///   a running app, but with none running it would bind the real path and answer the user's next `rookctl`;
///   the constructor alone binds nothing.
/// - `SettingsModel` takes the DEFAULT `SettingsStore` on purpose. Its init is a launch-time side-effect
///   engine: it writes `ghostty-settings.conf` into the STATE dir — a path it resolves from the
///   environment, not from its store's directory — and pushes ~15 values into the process-global
///   `GhosttyApp.shared`. With the real store it re-emits byte-identical text (so `writeGhosttyConfig`
///   no-ops) and re-applies the values the host app already applied at launch; a throwaway store would load
///   DEFAULTS and clobber the user's real generated config.
@MainActor
final class ControlServerHudResizeTests: XCTestCase {
    /// The width `makeFixture` opens the HUD at, inside `HudLayout`'s 10...80 clamp so the store keeps it
    /// verbatim and an unchanged value proves a refusal or a rollback rather than a clamp.
    private static let openedWidth = 40

    private struct Fixture {
        /// Retains the whole graph: `ControlServer` holds the library, actions and settings model.
        let server: ControlServer
        let store: AppStore
        let session: Session
        let directory: URL
        let bodyFile: URL
        /// The wire address of `session` — stored rather than computed, so reading it needs no actor hop.
        let target: String
    }

    private func makeFixture(hud: Bool = true) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rook-control-hud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let library = WindowLibrary(directory: directory)
        let server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore()),
            socketPath: directory.appendingPathComponent("unbound.sock").path
        )
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.workspaces.first?.sessions.first)
        // pin the font size so the cell measurement never falls back to the app-wide `GhosttyApp.shared`.
        session.fontSize = 13

        let bodyFile = directory.appendingPathComponent("hud-body.txt")
        if hud {
            XCTAssertTrue(store.openHud(session.id, command: "/bin/sh hud.sh",
                                        spec: HudSpec(message: "gathering options"),
                                        file: bodyFile.path,
                                        size: HudPanelSize(widthPercent: Self.openedWidth,
                                                           heightPercent: 12)))
        }
        return Fixture(server: server, store: store, session: session,
                       directory: directory, bodyFile: bodyFile, target: session.id.uuidString)
    }

    // MARK: - the `--full` refusal

    /// A HUD is always floating: `--full` (a nil percent on the wire) would make the message cover the
    /// session it is about, so the arm refuses before the store is touched.
    func testFullResizeIsRefusedForAHud() throws {
        let fixture = try makeFixture()
        let response = fixture.server.resizeSessionOverlay(fixture.target, window: nil, sizePercent: nil)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, OverlayHudError.fullResize)
        // refused BEFORE `resizeOverlay`, so the panel keeps the width it opened with and stays a HUD
        XCTAssertEqual(fixture.session.overlaySizePercent, Self.openedWidth)
        XCTAssertTrue(fixture.session.hudActive)
    }

    /// The refusal is scoped to a HUD, not to a nil percent: a caller's PROGRAM overlay still zooms to full.
    func testFullResizeStillWorksForAProgramOverlay() throws {
        let fixture = try makeFixture(hud: false)
        XCTAssertTrue(fixture.store.openOverlay(fixture.session.id, command: "/bin/sh", sizePercent: 40))
        let response = fixture.server.resizeSessionOverlay(fixture.target, window: nil, sizePercent: nil)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.id, fixture.target)
        XCTAssertNil(fixture.session.overlaySizePercent)
    }

    /// With the slot empty the `hud` conjunct is false, so a nil percent falls through to the ordinary
    /// empty-slot error rather than being explained as a HUD rule.
    func testFullResizeWithAnEmptySlotReportsNoOverlay() throws {
        let fixture = try makeFixture(hud: false)
        let response = fixture.server.resizeSessionOverlay(fixture.target, window: nil, sizePercent: nil)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "no overlay")
    }

    // MARK: - the write-failure rollback

    /// The happy path the rollback is measured against: the width lands and the body is rewritten, because
    /// the helper centers on the grid in that file's header.
    func testResizingAHudRewritesItsBody() throws {
        let fixture = try makeFixture()
        try Data("stale".utf8).write(to: fixture.bodyFile)
        let response = fixture.server.resizeSessionOverlay(fixture.target, window: nil, sizePercent: 25)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.id, fixture.target)
        XCTAssertEqual(fixture.session.overlaySizePercent, 25)
        let written = try String(contentsOf: fixture.bodyFile, encoding: .utf8)
        XCTAssertNotEqual(written, "stale")
        XCTAssertTrue(written.contains("gathering options"), "body was not rewritten: \(written)")
    }

    /// A refused write leaves the panel painting the OLD message, so the store must not keep the new width:
    /// the size and the file would disagree, and `tree` would report a width the panel never took.
    func testAFailedBodyWriteRollsTheWidthBack() throws {
        let fixture = try makeFixture()
        // the atomic write stages into the body file's own directory, so a missing parent is the
        // file-system refusal `writeHudBody` reports as false.
        fixture.session.hudFile = fixture.directory
            .appendingPathComponent("gone", isDirectory: true)
            .appendingPathComponent("hud-body.txt").path
        let response = fixture.server.resizeSessionOverlay(fixture.target, window: nil, sizePercent: 25)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, OverlayHudError.writeFailed)
        XCTAssertEqual(fixture.session.overlaySizePercent, Self.openedWidth)
        XCTAssertTrue(fixture.session.hudActive)
    }
}
