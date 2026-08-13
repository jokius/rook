import Foundation
import XCTest

// Where an UNADDRESSED `session.new` lands, and whether it steals the user's view. A `ControlAPITestCase`
// subclass so it reuses the shared harness (sendCommand / relaunch(withSnapshot:) / the snapshot-polling
// oracles) without duplicating scaffolding.
//
// The bug both halves fix: an agent's `rookctl session new` resolved `active`, which is the FRONTMOST
// window's CURRENT workspace — whatever its human happened to be looking at — and then selected the new
// session, yanking them out of it. `callerSession` (the `ROOK_SESSION_ID` the CLI stamps) names the
// caller's own workspace instead, and selection now follows `selectNewControlSession` (default off).
@MainActor
final class SessionNewPlacementUITests: ControlAPITestCase {
    private let callerID = UUID(uuidString: "A1110000-0000-0000-0000-000000000001")!
    private let visibleID = UUID(uuidString: "A2220000-0000-0000-0000-000000000002")!

    /// Two workspaces, one session each; the SELECTED session is the one in `ws visible`, so `active`
    /// resolves there while the caller lives in `ws caller`. That split is the whole point of the fixture.
    private func seedTwoWorkspaces() throws {
        let snapshot = """
        {"version":1,"selectedSessionID":"\(visibleID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"ws caller","sessions":[\
        {"id":"\(callerID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]},\
        {"id":"\(UUID().uuidString)","name":"ws visible","sessions":[\
        {"id":"\(visibleID.uuidString)","customName":null,"cwd":"\(NSHomeDirectory())"}]}]}
        """
        try relaunch(withSnapshot: snapshot)
        XCTAssertTrue(pollSessionCounts([1, 1], timeout: 10), "should start with one session per workspace")
    }

    // The headline case: the caller's session names the destination, so the new session joins the AGENT's
    // workspace even though the user is looking at another one — and the selection stays put.
    func testCallerSessionPlacesTheNewSessionInItsOwnWorkspace() throws {
        try seedTwoWorkspaces()

        let created = try sendCommand(#"{"cmd":"session.new","args":{"callerSession":"\#(callerID.uuidString)"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "session.new with a caller session should succeed: \(created)")
        XCTAssertTrue(pollSessionCounts([2, 1], timeout: 10),
                      "the new session should land in the caller's workspace, not the visible one")
        // the counts above already prove the create's save landed, so the selection read is settled.
        XCTAssertTrue(pollActiveSessionID(visibleID, timeout: 5),
                      "a control-created session must not pull the selection away from the user")
    }

    // Back-compat: with no caller (a script run outside rook), the destination is still the frontmost
    // window's current workspace. Only the SELECTION changed for this path.
    func testWithoutACallerTheCreateStillFollowsTheVisibleWorkspace() throws {
        try seedTwoWorkspaces()

        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "a plain session.new should succeed: \(created)")
        XCTAssertTrue(pollSessionCounts([1, 2], timeout: 10),
                      "with no caller the session should land in the visible workspace")
        XCTAssertTrue(pollActiveSessionID(visibleID, timeout: 5), "the selection should still not move")
    }

    // Explicit addressing outranks the implicit caller — the id rides on EVERY `rookctl session new`, so a
    // caller that names a workspace must win.
    func testExplicitWorkspaceOutranksTheCallerSession() throws {
        try seedTwoWorkspaces()
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let workspaces = try XCTUnwrap((result["tree"] as? [String: Any])?["workspaces"] as? [[String: Any]])
        let visibleWorkspace = try XCTUnwrap(workspaces.last?["id"] as? String, "second workspace id")

        let args = #"{"callerSession":"\#(callerID.uuidString)","workspace":"\#(visibleWorkspace)"}"#
        let created = try sendCommand(#"{"cmd":"session.new","args":\#(args)}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "explicit workspace + caller should succeed: \(created)")
        XCTAssertTrue(pollSessionCounts([1, 2], timeout: 10), "the named workspace should win over the caller")
    }

    // A stale id (a closed session, a `ROOK_SESSION_ID` exported into a detached process) degrades to the
    // pre-feature default instead of failing a create the caller never asked to address.
    func testAnUnresolvableCallerSessionFallsBackSilently() throws {
        try seedTwoWorkspaces()

        let stale = UUID().uuidString
        let created = try sendCommand(#"{"cmd":"session.new","args":{"callerSession":"\#(stale)"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "a stale caller session must not fail the create: \(created)")
        XCTAssertTrue(pollSessionCounts([1, 2], timeout: 10), "it should fall back to the visible workspace")
    }

    // `--select` is the per-call override for the background default: the new session becomes the selected
    // one wherever it lands.
    func testSelectForcesTheNewSessionToBeSelected() throws {
        try seedTwoWorkspaces()

        let args = #"{"callerSession":"\#(callerID.uuidString)","select":true}"#
        let created = try sendCommand(#"{"cmd":"session.new","args":\#(args)}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "session.new --select should succeed: \(created)")
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "the new session id")
        XCTAssertTrue(pollActiveSessionID(try XCTUnwrap(UUID(uuidString: newID)), timeout: 10),
                      "--select should move the selection to the new session")
    }

    // The Settings escape hatch: with `selectNewControlSession` on, an unflagged create selects again — the
    // pre-fix behavior, opted into rather than imposed.
    func testTheSettingRestoresSelectingCreates() throws {
        try seedTwoWorkspaces()
        try relaunch(withSettings: #"{"selectNewControlSession":true}"#)

        let created = try sendCommand(#"{"cmd":"session.new","args":{"callerSession":"\#(callerID.uuidString)"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "session.new should succeed: \(created)")
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "the new session id")
        XCTAssertTrue(pollActiveSessionID(try XCTUnwrap(UUID(uuidString: newID)), timeout: 10),
                      "the setting should restore selecting creates")
    }

    // Both selection flags at once is rejected server-side (a raw socket client bypasses the CLI's own
    // validate()), and nothing is created.
    func testSelectAndNoSelectTogetherAreRejected() throws {
        try seedTwoWorkspaces()

        let response = try sendCommand(#"{"cmd":"session.new","args":{"select":true,"noSelect":true}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false, "select + no-select should fail: \(response)")
        XCTAssertEqual(response["error"] as? String, "use either --select or --no-select, not both")
        XCTAssertTrue(pollSessionCounts([1, 1], timeout: 5), "the rejected call must not create a session")
    }
}
