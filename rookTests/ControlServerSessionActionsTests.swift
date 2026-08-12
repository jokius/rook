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
}
