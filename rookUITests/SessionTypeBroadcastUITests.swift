import Foundation
import XCTest

// Broadcast `session.type` e2e: one request, many sessions. A `ControlAPITestCase` subclass like
// `SessionTypePaneUITests`, reusing the shared harness (sendCommand / pollPaneText / activeSessionID).
// The read-back oracle is `session.text`, whose own pane routing is proven independently in
// `SessionTextUITests`.
//
// ORDERING DISCIPLINE, both cases: prove EVERY pane is ready first (each `pollPaneText` re-broadcasts per
// attempt, since a freshly-realized surface's shell can drop its first keystrokes — the `typeUntilMarker`
// readiness idiom), and only THEN assert the response fields on one FINAL broadcast. Reading `affected` off
// an earlier attempt races the pty: a session that wasn't ready yet answers a lower count, which would fail
// the test for a reason unrelated to the code — and on a UI target that costs the user their screen for
// nothing.
@MainActor
final class SessionTypeBroadcastUITests: ControlAPITestCase {
    // `--flagged` resolves the window's flagged working set and injects the SAME line into every member:
    // both sessions' buffers must carry the marker, and `result.affected` must report the count that
    // actually took it. The marker is an echo OUTPUT tag typed as `$((6*7))` arithmetic, so a match proves
    // the shell in that session RAN the line rather than merely echoing the keystrokes.
    func testSessionTypeFlaggedBroadcastReachesEveryFlaggedSession() throws {
        let first = try activeSessionID()
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let second = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String,
                                  "session.new should return the new id")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "the window should hold both sessions")
        try flag(first, second)

        let tag = "BCAST-\(UUID().uuidString.prefix(8))"
        let broadcast = broadcastRequest(text: "echo \(tag)-$((6*7))\n")
        // BOTH legs re-broadcast (the `echo` line is idempotent), so the fresh session gets further attempts
        // if its shell wasn't ready for the first. No inner ok assert — the base class sets
        // continueAfterFailure = false, so a transient failure would abort instead of letting the loop ride
        // it out; success is asserted below, via the markers and then the final count.
        let resend: () throws -> Void = { _ = try self.sendCommand(broadcast) }
        XCTAssertNotNil(try pollPaneText(target: first, pane: "left", contains: "\(tag)-42", retype: resend),
                        "the broadcast should reach the first flagged session")
        XCTAssertNotNil(try pollPaneText(target: second, pane: "left", contains: "\(tag)-42", retype: resend),
                        "the broadcast should reach the second flagged session too")

        // both shells are PROVEN ready now, so this call's count is deterministic.
        let settled = try sendCommand(broadcast)
        XCTAssertEqual(settled["ok"] as? Bool, true, "a fully-delivered broadcast should succeed: \(settled)")
        XCTAssertEqual((settled["result"] as? [String: Any])?["affected"] as? Int, 2,
                       "a two-session broadcast should report affected: 2")
    }

    // A PARTIAL delivery must not be dressed up as success: `ok: false` carrying the first error AND the
    // truthful count of sessions that DID take the text. Only the SECOND session gets a split, so a
    // `--pane right` broadcast fails on the FIRST target and succeeds on the second — deliberately that
    // order, because it is the arrangement that catches a loop stopping at the first error (which would
    // report `affected: 0`). It assumes the flagged set follows sidebar order; the ok/error/count asserts
    // hold either way, only the don't-skip-later-targets strength depends on it.
    func testSessionTypeBroadcastReportsPartialDeliveryWithoutClaimingSuccess() throws {
        let paneless = try activeSessionID()
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let split = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String,
                                 "session.new should return the new id")
        let opened = try sendCommand(#"{"cmd":"session.split","target":"\#(split)","args":{"mode":"on"}}"#)
        XCTAssertEqual(opened["ok"] as? Bool, true, "split on should succeed: \(opened)")
        try flag(paneless, split)

        let tag = "BPART-\(UUID().uuidString.prefix(8))"
        let broadcast = broadcastRequest(text: "echo \(tag)-$((6*7))\n", pane: "right")
        // the split pane is freshly spawned, so re-broadcast until its shell RAN the line: that marker is
        // both the readiness proof and the evidence the SECOND target was reached despite the first failing.
        XCTAssertNotNil(try pollPaneText(target: split, pane: "right", contains: "\(tag)-42",
                                         retype: { _ = try self.sendCommand(broadcast) }),
                        "--pane right should reach the split session's pane")

        // the only failure left is the session that HAS no split pane, so this call is deterministic.
        let settled = try sendCommand(broadcast)
        XCTAssertEqual(settled["ok"] as? Bool, false, "a partial broadcast must not report success: \(settled)")
        XCTAssertEqual(settled["error"] as? String, "session has no split pane",
                       "the failing target's error should be reported: \(settled)")
        XCTAssertEqual((settled["result"] as? [String: Any])?["affected"] as? Int, 1,
                       "the session that DID take the text must still be counted: \(settled)")
    }

    /// Flag every session in `ids` — the set `--flagged` broadcasts to — asserting each call succeeds.
    private func flag(_ ids: String...) throws {
        for id in ids {
            let flagged = try sendCommand(#"{"cmd":"session.flag","target":"\#(id)","args":{"mode":"on"}}"#)
            XCTAssertEqual(flagged["ok"] as? Bool, true, "flagging \(id) should succeed: \(flagged)")
        }
    }

    /// Build a flagged-broadcast `session.type` request line with JSON-escaped `text` (the shared
    /// `typeRequest` helper only knows the single-target form); `pane` addresses one pane in EVERY target.
    private func broadcastRequest(text: String, pane: String? = nil) -> String {
        var args: [String: Any] = ["text": text, "flagged": true]
        if let pane { args["pane"] = pane }
        let data = try! JSONSerialization.data(withJSONObject: ["cmd": "session.type", "args": args])
        return String(data: data, encoding: .utf8)!
    }
}
