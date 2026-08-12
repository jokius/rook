import rookCore
import XCTest
@testable import rook

/// Hosted coverage for the `ControlServer` session arms whose decision needs a LIVE `GhosttySurfaceView` and
/// therefore cannot move to `rookCore` — the dispatcher hands the request straight to the `ControlActions`
/// witness and the arm reads the surface itself.
///
/// The fixture follows the three constraints the control-api rule records (see `ControlServerHudResizeTests`):
/// the `WindowLibrary` is rooted in a throwaway directory, `SettingsModel` takes the DEFAULT `SettingsStore`,
/// and the server is NEVER `start()`ed — the constructor alone binds nothing.
@MainActor
final class ControlServerSessionActionsTests: XCTestCase {
    private struct Fixture {
        /// Retains the whole graph: `ControlServer` holds the library, actions and settings model.
        let server: ControlServer
        let store: AppStore
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rook-control-session-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let library = WindowLibrary(directory: directory)
        let server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore()),
            socketPath: directory.appendingPathComponent("unbound.sock").path
        )
        return Fixture(server: server, store: try XCTUnwrap(library.activeStore))
    }

    // a pane parked in the slot with no libghostty surface is the state a display-asleep create leaves
    // behind. It used to answer `failed to read surface buffer`, naming a cause that never happened, while
    // every sibling command called the same state `session not realized`.
    func testTextOnAnUnrealizedPaneReportsNotRealizedRatherThanAReadFailure() throws {
        let fixture = try makeFixture()
        let owner = try XCTUnwrap(fixture.store.currentWorkspaceID)
        let target = try XCTUnwrap(fixture.store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let parked = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        target.surface = parked
        XCTAssertFalse(parked.isRealized, "a detached view never runs createSurface, which is the point here")

        let response = fixture.server.readSessionText(target.id.uuidString, window: nil,
                                                     options: ControlSessionTextOptions(pane: nil, all: false,
                                                                                        lines: nil))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "session not realized",
                       "an empty slot and a parked-but-unrealized view are one state to a caller")
    }

    /// A fresh session in the fixture's store with a split OPEN (`hasSplit` + `isSplit` + `splitFocused`).
    private func splitSession(_ fixture: Fixture) throws -> Session {
        let owner = try XCTUnwrap(fixture.store.currentWorkspaceID)
        let session = try XCTUnwrap(fixture.store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        fixture.store.toggleSplit(session.id)
        return session
    }

    // `session.split off` only HIDES the pane; the close verb is the one that tears it down, so every flag
    // that rides on the pane — including the geometry a later split would otherwise inherit — has to go.
    func testSplitCloseTearsThePaneDown() throws {
        let fixture = try makeFixture()
        let session = try splitSession(fixture)
        session.splitRatio = 0.7

        let response = fixture.server.closeSessionSplit(session.id.uuidString, window: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.id, session.id.uuidString)
        XCTAssertFalse(session.hasSplit)
        XCTAssertFalse(session.isSplit)
        XCTAssertFalse(session.splitFocused)
        XCTAssertNil(session.splitRatio)
    }

    // a HIDDEN pane is exactly the case the command exists for: `isSplit` is already false while the shell
    // is still alive, so the arm must gate on `hasSplit` rather than on what is on screen.
    func testSplitCloseReachesAHiddenPane() throws {
        let fixture = try makeFixture()
        let session = try splitSession(fixture)
        fixture.store.toggleSplit(session.id) // hide it, keep-alive
        XCTAssertTrue(session.hasSplit)
        XCTAssertFalse(session.isSplit)

        let response = fixture.server.closeSessionSplit(session.id.uuidString, window: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertFalse(session.hasSplit)
    }

    // idempotent by contract: a script may close without reading `tree` first, so no right pane answers ok.
    func testSplitCloseWithoutASplitAnswersOk() throws {
        let fixture = try makeFixture()
        let owner = try XCTUnwrap(fixture.store.currentWorkspaceID)
        let session = try XCTUnwrap(fixture.store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))

        let response = fixture.server.closeSessionSplit(session.id.uuidString, window: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertFalse(session.hasSplit)
    }

    // the idempotent ok above must not swallow a target that does not exist — a typo'd id has to fail
    // rather than quietly report success against the active session.
    func testSplitCloseRejectsAnUnknownSession() throws {
        let fixture = try makeFixture()

        let response = fixture.server.closeSessionSplit(UUID().uuidString, window: nil)

        XCTAssertFalse(response.ok)
    }
}
