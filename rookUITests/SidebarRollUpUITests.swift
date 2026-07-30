import Foundation
import XCTest

/// Control-channel e2e for the andon roll-up: a COLLAPSED workspace row wears the agent-status glyph of its
/// worst child (`Workspace.rollUpIndicator`), so a blocked agent inside a folded workspace stays visible —
/// and a row whose sessions are on screen drops it again, since the children's own glyphs already say the
/// same thing. Subclass of `ControlAPITestCase` for the socket harness (isolated `ROOK_STATE_DIR` + short
/// socket path). No synthetic keyboard or mouse input: everything is driven over the control socket and read
/// back through the accessibility tree.
///
/// Oracle (deterministic, by elimination + row identity): the AX tree is flat — `agent-status` carries no
/// hint of the row it belongs to — so both cases arrange for the WORKSPACE row to be the only row that CAN
/// own a glyph. The blocked session lives in a workspace created `--collapsed` and filled in the background,
/// so its own `session-row` is never rendered, and the only other session (the seeded one) stays idle. Under
/// those conditions a glyph existing at all can only be a workspace row's roll-up, its `accessibilityValue`
/// (= the status raw value, the one status property the AX tree exposes — neither the tint nor the silhouette
/// is observable) says which child won, and `workspaceRowNearestTheGlyph()` pins WHICH workspace row grew it,
/// so a glyph leaking onto the wrong row (cell reuse) fails instead of passing. Where the child's row IS
/// rendered the oracle switches to the glyph COUNT: exactly one, so a parent glyph left behind reads as two.
///
/// The rank itself (blocked > completed > active > idle, and why it is not `attentionRank`) is covered
/// host-free in `WorkspaceRollUpTests`; these drive the two things a unit test cannot see — that the glyph
/// reaches the live outline, and that it follows the row's VISUAL collapse state rather than the persisted
/// one.
@MainActor
final class SidebarRollUpUITests: ControlAPITestCase {
    func testCollapsedWorkspaceRowWearsItsWorstChildStatusGlyph() throws {
        let folded = try seedFoldedBlockedWorkspace()

        // the collapsed workspace row grows the roll-up glyph, reporting its blocked child's state.
        XCTAssertTrue(pollStatusGlyphs(count: 1, value: "blocked", timeout: 12),
                      "a collapsed workspace should roll up its blocked child's glyph, glyphs: \(glyphValues())")
        XCTAssertEqual(workspaceRowNearestTheGlyph(), foldedWorkspaceName,
                       "the glyph should sit on the FOLDED workspace's row, not another one")
        XCTAssertEqual(sessionRowCount, 1, "the roll-up must not have revealed the folded session's row")

        // expanding shows the child's OWN glyph and drops the parent's — on an expanded row the roll-up would
        // duplicate a state the session rows already carry.
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.expand","target":"\#(folded.workspace)"}"#)["ok"] as? Bool,
                       true, "workspace.expand should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "expanding should render the folded session's row")
        XCTAssertTrue(pollStatusGlyphs(count: 1, value: "blocked", timeout: 12),
                      "exactly one glyph should remain (the session's own) — a leftover parent glyph makes two, glyphs: \(glyphValues())")

        // re-collapsing brings the roll-up back, so it tracks the row's state rather than firing once.
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.collapse","target":"\#(folded.workspace)"}"#)["ok"] as? Bool,
                       true, "workspace.collapse should succeed")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "collapsing should fold the session row away again")
        XCTAssertTrue(pollStatusGlyphs(count: 1, value: "blocked", timeout: 12),
                      "the roll-up should return on re-collapse, glyphs: \(glyphValues())")

        // clearing the child's status empties the roll-up: an all-idle collapsed workspace renders no glyph
        // at all (the row's status slot collapses to zero width).
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.status","target":"\#(folded.session)","args":{"status":"idle"}}"#)["ok"] as? Bool,
                       true, "session.status idle should succeed")
        XCTAssertTrue(app.staticTexts["agent-status"].waitForNonExistence(timeout: 12),
                      "an all-idle collapsed workspace should render no glyph, glyphs: \(glyphValues())")
    }

    // the FORCE-REVEAL case: selecting a session inside a collapsed workspace expands its owner VIEW-ONLY
    // (`WorkspaceSidebar.syncSelection` brackets `expandItem` in `suppressExpansionPersist`), so the rows come
    // on screen while the workspace stays collapsed ON DISK. The roll-up must follow what is VISIBLE and go
    // away — it is gated on the visual expansion set, not on the persisted `Workspace.isExpanded`.
    //
    // The `collapsed: true` read-back after the reveal is the load-bearing half: it is the measurement that
    // separates the two possible implementations. Without it a roll-up wrongly gated on the persisted flag
    // would ALSO pass this test, because the persisted flag is what a socket-driven collapse writes.
    func testForceRevealedRowsDropTheRollUpWithoutUnCollapsingTheWorkspace() throws {
        let folded = try seedFoldedBlockedWorkspace()
        XCTAssertTrue(pollStatusGlyphs(count: 1, value: "blocked", timeout: 12),
                      "the folded workspace should carry the roll-up before the reveal, glyphs: \(glyphValues())")
        XCTAssertEqual(workspaceRowNearestTheGlyph(), foldedWorkspaceName,
                       "the pre-reveal glyph should sit on the FOLDED workspace's row")

        // selecting the hidden session reveals its owner's rows without touching the persisted state.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(folded.session)"}"#)["ok"] as? Bool,
                       true, "session.select of the folded session should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10),
                      "selecting the hidden session should reveal its row (the view-only expand)")

        // its rows are on screen now, so the parent must not carry a duplicate: exactly ONE glyph, the
        // revealed session's own.
        XCTAssertTrue(pollStatusGlyphs(count: 1, value: "blocked", timeout: 12),
                      "a force-revealed workspace must drop its roll-up — a kept parent glyph makes two, glyphs: \(glyphValues())")

        // and the reveal really was view-only: the workspace is still collapsed on disk. Read AFTER the rows
        // landed, so the reveal has definitely happened by the time the flag is checked.
        XCTAssertEqual(try workspaceCollapsed(folded.workspace), true,
                       "the view-only reveal must leave the workspace persisted-collapsed — otherwise this case proves nothing about which state the roll-up is gated on")
    }

    /// The displayed name of the workspace both cases fold.
    private var foldedWorkspaceName: String { "flock" }

    /// Builds the shared fixture: a workspace created `--collapsed`, filled with ONE background session
    /// (`--no-select`, so the create doesn't view-only expand the owner and reveal it), whose agent then
    /// blocks. Returns both ids. Asserts the seeding itself — that the workspace really is folded and its
    /// session's row really is unrendered — so a case that follows can attribute any glyph to a workspace row.
    private func seedFoldedBlockedWorkspace() throws -> (workspace: String, session: String) {
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "the seeded session should be the only row")
        XCTAssertTrue(app.staticTexts["agent-status"].waitForNonExistence(timeout: 5),
                      "no glyph should exist before any status is set")

        let workspace = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"\#(foldedWorkspaceName)","collapsed":true}}"#)
        XCTAssertEqual(workspace["ok"] as? Bool, true, "workspace.new --collapsed should succeed: \(workspace)")
        let wsID = try XCTUnwrap((workspace["result"] as? [String: Any])?["id"] as? String,
                                 "workspace.new should return an id")

        let created = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(wsID)","noSelect":true}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "a background session.new should succeed: \(created)")
        let sessionID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String,
                                      "session.new should return an id")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "the folded workspace's session row must stay hidden")
        XCTAssertEqual(try workspaceCollapsed(wsID), true, "the fixture workspace should start collapsed")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.status","target":"\#(sessionID)","args":{"status":"blocked"}}"#)["ok"] as? Bool,
                       true, "session.status blocked should succeed")
        return (wsID, sessionID)
    }

    /// The `collapsed` flag of one workspace node in a freshly built tree — `true` when collapsed, nil when
    /// EXPANDED (the field is omitted, expanded being the default).
    private func workspaceCollapsed(_ id: String) throws -> Bool? {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let nodes = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let node = try XCTUnwrap(nodes.first { $0["id"] as? String == id }, "workspace \(id) should be in the tree")
        return node["collapsed"] as? Bool
    }

    /// Polls until exactly `count` `agent-status` glyphs exist and every one of them reports `value`.
    /// A BOUNDED wait in both directions: the sidebar reloads the changed row asynchronously, so a one-shot
    /// read would pass (or fail) before the outline had a chance to settle.
    private func pollStatusGlyphs(count: Int, value: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if glyphValues() == Array(repeating: value, count: count) { return true }
            usleep(200_000)
        }
        return glyphValues() == Array(repeating: value, count: count)
    }

    /// The `accessibilityValue` of every `agent-status` glyph in the tree — the failure detail that tells a
    /// MISSING roll-up (`[]`) apart from a DUPLICATED one (`["blocked", "blocked"]`).
    private func glyphValues() -> [String] {
        statusGlyphs.allElementsBoundByIndex.map { $0.value as? String ?? "<no value>" }
    }

    /// The name of the `workspace-row` whose label sits NEAREST the first glyph vertically — the row the glyph
    /// is rendered on. The AX tree is flat (the glyph is a sibling view inside the cell, with no queryable
    /// parent-row relationship), so row identity has to come from geometry. Nearest rather than an exact
    /// centre match, which keeps it free of any assumption about how the icon is aligned inside its cell: all
    /// it needs is that a glyph is closer to its own row's label than to another row's.
    private func workspaceRowNearestTheGlyph() -> String? {
        guard let glyph = statusGlyphs.allElementsBoundByIndex.first else { return nil }
        let rows = app.staticTexts.matching(identifier: "workspace-row").allElementsBoundByIndex
        let nearest = rows.min { abs($0.frame.midY - glyph.frame.midY) < abs($1.frame.midY - glyph.frame.midY) }
        return nearest?.value as? String
    }

    private var statusGlyphs: XCUIElementQuery { app.staticTexts.matching(identifier: "agent-status") }

    private var sessionRowCount: Int { app.staticTexts.matching(identifier: "session-row").count }
}
