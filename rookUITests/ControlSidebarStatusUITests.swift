import Foundation
import XCTest

/// Control-channel e2e for the sidebar visibility/mode/expand-collapse, workspace focus, session
/// flag, agent-status glyph, and notification-badge behaviors. Subclass of `ControlAPITestCase`.
@MainActor
final class ControlSidebarStatusUITests: ControlAPITestCase {
    // an OSC 9 desktop notification from an UNFOCUSED pane badges its sidebar row, and selecting the
    // session clears it. Fire into the seeded session (realized at launch) after a new session takes
    // focus, so suppression doesn't drop it and no --select (which would re-focus it) is needed.
    func testUnfocusedNotificationBadgesRowAndClearsOnSelect() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // a second session takes focus, leaving the seeded one realized but unfocused.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.new"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the new session should land")

        // emit OSC 9 from the unfocused seeded session (printf interprets the octal escapes).
        let typed = try sendCommand(typeRequest(text: "printf '\\033]9;rook test\\007'\n", target: seeded, select: false))
        XCTAssertEqual(typed["ok"] as? Bool, true, "typing into the realized seeded session should succeed: \(typed)")

        XCTAssertTrue(app.staticTexts["notify-badge"].waitForExistence(timeout: 12),
                      "an unseen badge should appear on the unfocused session's row")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seeded)"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForNonExistence(timeout: 12),
                      "selecting the session should clear its badge")
    }

    // the `sidebar` control command shows/hides the custom sidebar (the custom split has no system
    // toggle). hiding removes the session rows from the AX tree; showing restores them. mode is
    // show|hide|toggle on the frontmost window, and an unknown mode is an error.
    func testSidebarShowHideToggle() throws {
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 10), "sidebar should start visible")

        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar","args":{"mode":"hide"}}"#)["ok"] as? Bool, true,
                       "sidebar hide should succeed")
        XCTAssertTrue(app.staticTexts["session-row"].waitForNonExistence(timeout: 10),
                      "hiding the sidebar should remove the session rows")

        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar","args":{"mode":"show"}}"#)["ok"] as? Bool, true,
                       "sidebar show should succeed")
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 10),
                      "showing the sidebar should restore the session rows")

        let bad = try sendCommand(#"{"cmd":"sidebar","args":{"mode":"sideways"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an invalid sidebar mode should error")
    }

    // session.flag flags a session for the flagged working-set view; sidebar.mode flagged switches the
    // sidebar to the flat list of just the flagged sessions (each labeled "session : workspace"), so an
    // unflagged session's row is absent in flagged mode and returns when switched back to tree.
    func testSessionFlagAndSidebarModeFlagged() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        // name the seeded session and add a second one, so the two are distinguishable by name.
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let t = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let ws = try XCTUnwrap((t["workspaces"] as? [[String: Any]])?.first, "should have a workspace")
        let seededID = try XCTUnwrap((ws["sessions"] as? [[String: Any]])?.first?["id"] as? String, "should have a seeded session")

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seededID)","args":{"name":"flagme"}}"#)["ok"] as? Bool,
                       true, "renaming the seeded session should succeed")
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let newID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(newID)","args":{"name":"keepme"}}"#)["ok"] as? Bool,
                       true, "renaming the new session should succeed")

        // both rows present in tree mode.
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both session rows should be present in tree mode")

        // flag the seeded session.
        let flag = try sendCommand(#"{"cmd":"session.flag","target":"\#(seededID)","args":{"mode":"on"}}"#)
        XCTAssertEqual(flag["ok"] as? Bool, true, "session.flag on should succeed: \(flag)")

        // switch to the flat flagged view: exactly one row, the flagged "flagme", labeled with its
        // workspace; the unflagged "keepme" row is absent.
        let mode = try sendCommand(#"{"cmd":"sidebar.mode","args":{"mode":"flagged"}}"#)
        XCTAssertEqual(mode["ok"] as? Bool, true, "sidebar.mode flagged should succeed: \(mode)")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "flagged mode should show only the one flagged row")
        XCTAssertTrue(sessionRowValueExists(containing: "flagme"), "the flagged session's row should be present")
        XCTAssertFalse(sessionRowValueExists(containing: "keepme"), "the unflagged session's row should be absent")

        // toggling back to the tree restores both rows.
        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar.mode","args":{"mode":"toggle"}}"#)["ok"] as? Bool, true,
                       "sidebar.mode toggle should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "toggling back to tree restores the full tree")

        // session.flag clear unflags everything: flag BOTH, view the flat list (two rows), then clear → the
        // flagged view empties (zero rows).
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.flag","target":"\#(newID)","args":{"mode":"on"}}"#)["ok"] as? Bool,
                       true, "flagging the second session should succeed")
        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar.mode","args":{"mode":"flagged"}}"#)["ok"] as? Bool, true,
                       "switching to flagged should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both flagged rows should be present")
        let cleared = try sendCommand(#"{"cmd":"session.flag","args":{"mode":"clear"}}"#)
        XCTAssertEqual(cleared["ok"] as? Bool, true, "session.flag clear should succeed: \(cleared)")
        XCTAssertTrue(pollSessionRowCount(0, timeout: 10), "clearing all flags empties the flagged view")
        // back to the tree so the invalid-mode check below runs against the full tree.
        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar.mode","args":{"mode":"tree"}}"#)["ok"] as? Bool, true,
                       "switching back to tree should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "the sessions themselves are not closed by clear")

        // an invalid mode errors rather than silently no-opping.
        let bad = try sendCommand(#"{"cmd":"sidebar.mode","args":{"mode":"bogus"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an invalid sidebar mode should error: \(bad)")
        XCTAssertTrue((bad["error"] as? String ?? "").contains("invalid sidebar mode"), "should report invalid mode: \(bad)")
    }

    // workspace.focus `on` REPLACES the marked set with one workspace and applies the filter, so the tree
    // collapses to that workspace's subtree — the other workspaces' session rows leave the AX tree. `add`
    // then widens the set back out and `off` removes a single member, each leaving the filter FLAG alone.
    // Orthogonal to the flagged view.
    func testWorkspaceFocusHidesOtherWorkspaces() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        // capture the seeded workspace + session, name the session so it's findable by value.
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let t = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let ws = try XCTUnwrap((t["workspaces"] as? [[String: Any]])?.first, "should have a workspace")
        let firstWsID = try XCTUnwrap(ws["id"] as? String, "should have a seeded workspace id")
        let seededID = try XCTUnwrap((ws["sessions"] as? [[String: Any]])?.first?["id"] as? String, "should have a seeded session")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seededID)","args":{"name":"stay"}}"#)["ok"] as? Bool,
                       true, "renaming the seeded session should succeed")

        // add a second workspace with its own session.
        let newWs = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"second"}}"#)
        let secondWsID = try XCTUnwrap((newWs["result"] as? [String: Any])?["id"] as? String, "workspace.new should return an id")
        let created = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(secondWsID)"}}"#)
        let newSessID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(newSessID)","args":{"name":"hidden"}}"#)["ok"] as? Bool,
                       true, "renaming the new session should succeed")

        // both rows present in the unfocused tree.
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both session rows should be present unfocused")

        // select the first workspace's session (so the active session is inside the workspace we focus),
        // then focus the FIRST workspace: the second workspace's session row disappears.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seededID)"}"#)["ok"] as? Bool, true,
                       "selecting the seeded session should succeed")
        let focus = try sendCommand(#"{"cmd":"workspace.focus","target":"\#(firstWsID)","args":{"mode":"on"}}"#)
        XCTAssertEqual(focus["ok"] as? Bool, true, "workspace.focus on should succeed: \(focus)")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "focusing one workspace should hide the other's rows")
        XCTAssertTrue(sessionRowValueExists(containing: "stay"), "the focused workspace's session should remain")
        XCTAssertFalse(sessionRowValueExists(containing: "hidden"), "the other workspace's session should be hidden")

        // workspace.focus off is the REMOVE mode — it drops THIS workspace from the marked set — so on a
        // workspace that was never a member it is a no-op for that reason, not because "only the focused
        // one can be unfocused" (the old single-mark model's reason, which this assertion used to carry).
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(secondWsID)","args":{"mode":"off"}}"#)["ok"] as? Bool,
                       true, "workspace.focus off on a non-member workspace should succeed (no-op)")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "removing a non-member must leave the applied set unchanged")
        XCTAssertTrue(sessionRowValueExists(containing: "stay"), "the member workspace's session should still remain")
        XCTAssertFalse(sessionRowValueExists(containing: "hidden"), "the non-member's session should still be hidden")

        // the case the single-mark model could not express: `add` widens the APPLIED set to two members —
        // and, the other polarity of the marking rule, an add never touches the filter FLAG, so a filter
        // that was ON stays on (with the filter OFF two adds leave it off — testWorkspaceFocusAddBuildsMultiWorkspaceSet).
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(secondWsID)","args":{"mode":"add"}}"#)["ok"] as? Bool,
                       true, "workspace.focus add should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "adding the second workspace should reveal its rows")
        XCTAssertTrue(sessionRowValueExists(containing: "hidden"), "the newly added member's session should appear")
        XCTAssertEqual(try focusState(ofWorkspace: secondWsID).filter, true,
                       "an add must not switch a filter that is already on back off")

        // …and `off` on a MEMBER of a multi-member set removes just that one, leaving the rest marked AND
        // filtering — the set shrinks by one instead of collapsing.
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(secondWsID)","args":{"mode":"off"}}"#)["ok"] as? Bool,
                       true, "workspace.focus off on a member should succeed")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "removing one of two members should hide only that workspace")
        XCTAssertTrue(sessionRowValueExists(containing: "stay"), "the surviving member's session should remain")
        XCTAssertFalse(sessionRowValueExists(containing: "hidden"), "the removed member's session should be hidden again")
        let survivor = try focusState(ofWorkspace: firstWsID)
        XCTAssertEqual(survivor.marked, true, "the surviving member should still be marked")
        XCTAssertEqual(survivor.focused, true, "…and still effectively focused")
        XCTAssertEqual(survivor.filter, true, "…because removing one of two members leaves the filter applied")

        // removing the LAST member empties the set, which disables the filter and restores the full tree.
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(firstWsID)","args":{"mode":"off"}}"#)["ok"] as? Bool,
                       true, "workspace.focus off should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "unfocusing should restore the full tree")

        // an invalid mode errors rather than silently no-opping.
        let bad = try sendCommand(#"{"cmd":"workspace.focus","target":"\#(firstWsID)","args":{"mode":"bogus"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an invalid focus mode should error: \(bad)")
        XCTAssertTrue((bad["error"] as? String ?? "").contains("invalid focus mode"), "should report invalid mode: \(bad)")
    }

    // workspace.color sets the workspace's sidebar icon tint and reads back on the tree node, so a script
    // can record-then-restore it; `clear` resets it and a malformed hex errors without mutating. The TINT
    // itself is not accessibility-observable (like the status glyph's --color), so this asserts the command
    // path + the read-back, which is what a driving script depends on.
    func testWorkspaceColorSetAndClear() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let t = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let ws = try XCTUnwrap((t["workspaces"] as? [[String: Any]])?.first, "should have a workspace")
        let wsID = try XCTUnwrap(ws["id"] as? String, "should have a seeded workspace id")
        XCTAssertNil(ws["color"], "an uncolored workspace must omit `color` from the tree node")

        // set: the node reads back the hex we wrote. NOTE the ##"…"## delimiter — a plain #"…"# literal
        // would be CLOSED early by the `"#` in `"#ff8800"`.
        let set = try sendCommand(##"{"cmd":"workspace.color","target":"\##(wsID)","args":{"color":"#ff8800"}}"##)
        XCTAssertEqual(set["ok"] as? Bool, true, "workspace.color should succeed: \(set)")
        XCTAssertEqual(try workspaceColor(ofWorkspace: wsID), "#ff8800", "the tree node should read back the color")

        // a malformed color errors and leaves the existing color untouched.
        let bad = try sendCommand(#"{"cmd":"workspace.color","target":"\#(wsID)","args":{"color":"orange"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "a malformed color should error: \(bad)")
        XCTAssertTrue((bad["error"] as? String ?? "").contains("invalid color"), "should report an invalid color: \(bad)")
        XCTAssertEqual(try workspaceColor(ofWorkspace: wsID), "#ff8800", "a rejected color must not overwrite the current one")

        // clear: back to the theme default, so the field is omitted again.
        let cleared = try sendCommand(#"{"cmd":"workspace.color","target":"\#(wsID)","args":{"color":"clear"}}"#)
        XCTAssertEqual(cleared["ok"] as? Bool, true, "workspace.color clear should succeed: \(cleared)")
        XCTAssertNil(try workspaceColor(ofWorkspace: wsID), "a cleared workspace must omit `color` again")
    }

    /// The `color` field of one workspace node in a freshly built tree (nil when omitted).
    private func workspaceColor(ofWorkspace id: String) throws -> String? {
        try workspaceNode(id)["color"] as? String
    }

    // workspace.icon sets the sidebar icon from an SF Symbol name, an emoji, or an image file, and reads
    // back on the tree node as `icon` + `iconKind` so a script can restore it. An unknown symbol errors
    // rather than silently falling back to the default glyph.
    func testWorkspaceIconSetAndClear() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        let ws = try XCTUnwrap((try workspaceNodes()).first, "should have a workspace")
        let wsID = try XCTUnwrap(ws["id"] as? String, "should have a seeded workspace id")
        XCTAssertNil(ws["icon"], "a workspace on the default glyph must omit `icon`")

        // an SF Symbol name
        let symbol = try sendCommand(#"{"cmd":"workspace.icon","target":"\#(wsID)","args":{"icon":"hammer.fill"}}"#)
        XCTAssertEqual(symbol["ok"] as? Bool, true, "workspace.icon should succeed: \(symbol)")
        XCTAssertEqual(try workspaceNode(wsID)["icon"] as? String, "hammer.fill")
        XCTAssertEqual(try workspaceNode(wsID)["iconKind"] as? String, "symbol")

        // an emoji is classified on its own, no flag needed
        let emoji = try sendCommand(#"{"cmd":"workspace.icon","target":"\#(wsID)","args":{"icon":"🚀"}}"#)
        XCTAssertEqual(emoji["ok"] as? Bool, true, "an emoji icon should succeed: \(emoji)")
        XCTAssertEqual(try workspaceNode(wsID)["iconKind"] as? String, "emoji")

        // an unknown symbol errors instead of silently rendering the default glyph, and leaves the icon alone
        let bad = try sendCommand(#"{"cmd":"workspace.icon","target":"\#(wsID)","args":{"icon":"definitely.not.a.symbol"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an unknown SF Symbol should error: \(bad)")
        XCTAssertTrue((bad["error"] as? String ?? "").contains("unknown SF Symbol"), "should name the problem: \(bad)")
        XCTAssertEqual(try workspaceNode(wsID)["iconKind"] as? String, "emoji", "a rejected icon must not overwrite")

        // clear restores the default glyph
        let cleared = try sendCommand(#"{"cmd":"workspace.icon","target":"\#(wsID)","args":{"icon":"clear"}}"#)
        XCTAssertEqual(cleared["ok"] as? Bool, true, "workspace.icon clear should succeed: \(cleared)")
        XCTAssertNil(try workspaceNode(wsID)["icon"], "a cleared workspace must omit `icon` again")
        XCTAssertNil(try workspaceNode(wsID)["iconKind"])
    }

    /// The `tree` root object (`result.tree`) — the top-level fields plus `workspaces`.
    private func treeRoot() throws -> [String: Any] {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        return try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
    }

    private func workspaceNodes() throws -> [[String: Any]] {
        try XCTUnwrap(try treeRoot()["workspaces"] as? [[String: Any]], "tree should carry workspaces")
    }

    private func workspaceNode(_ id: String) throws -> [String: Any] {
        try XCTUnwrap((try workspaceNodes()).first { $0["id"] as? String == id }, "workspace \(id) should be in the tree")
    }

    // sidebar.collapse collapses every workspace except the active session's — the others' session rows
    // leave the AX tree while the active workspace's stay; sidebar.expand re-expands every workspace and
    // restores them.
    func testSidebarExpandCollapse() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        // capture the seeded workspace + session, name the session so it's findable by value.
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let t = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let ws = try XCTUnwrap((t["workspaces"] as? [[String: Any]])?.first, "should have a workspace")
        let seededID = try XCTUnwrap((ws["sessions"] as? [[String: Any]])?.first?["id"] as? String, "should have a seeded session")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seededID)","args":{"name":"stay"}}"#)["ok"] as? Bool,
                       true, "renaming the seeded session should succeed")

        // add a second workspace with its own session in a different workspace.
        let newWs = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"second"}}"#)
        let secondWsID = try XCTUnwrap((newWs["result"] as? [String: Any])?["id"] as? String, "workspace.new should return an id")
        let created = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(secondWsID)"}}"#)
        let newSessID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(newSessID)","args":{"name":"hidden"}}"#)["ok"] as? Bool,
                       true, "renaming the new session should succeed")

        // both rows present with both workspaces expanded (the sidebar expands all on launch).
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both session rows should be present expanded")

        // select the seeded session so the ACTIVE workspace is the first one, then collapse: the second
        // workspace folds away (its "hidden" row leaves the AX tree) while the active workspace stays open.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seededID)"}"#)["ok"] as? Bool, true,
                       "selecting the seeded session should succeed")
        let collapse = try sendCommand(#"{"cmd":"sidebar.collapse"}"#)
        XCTAssertEqual(collapse["ok"] as? Bool, true, "sidebar.collapse should succeed: \(collapse)")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "collapse should hide the non-active workspace's rows")
        XCTAssertTrue(sessionRowValueExists(containing: "stay"), "the active workspace's session should remain")
        XCTAssertFalse(sessionRowValueExists(containing: "hidden"), "the collapsed workspace's session should be hidden")

        // expand re-opens every workspace and restores both rows.
        let expand = try sendCommand(#"{"cmd":"sidebar.expand"}"#)
        XCTAssertEqual(expand["ok"] as? Bool, true, "sidebar.expand should succeed: \(expand)")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "expand should restore every workspace's rows")
        XCTAssertTrue(sessionRowValueExists(containing: "hidden"), "the collapsed workspace's session should return")
    }

    /// Whether any `session-row` exposes `needle` in its accessibility value (the row's displayed name —
    /// `session : workspace` in flagged mode). The sidebar surfaces the row name via `value`, not `label`.
    private func sessionRowValueExists(containing needle: String) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND value CONTAINS %@", "session-row", needle))
            .firstMatch.exists
    }

    /// Polls until a `session-row` carrying `needle` in its value exists (`wanted == true`) or is gone
    /// (`wanted == false`), returning whether that state was reached inside `timeout`. The negative form is a
    /// BOUNDED wait, not a one-shot: a broken collapse reveals the row asynchronously, so `XCTAssertFalse` on
    /// a single immediate read would pass before the outline had a chance to be wrong.
    private func pollSessionRowValue(_ needle: String, exists wanted: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sessionRowValueExists(containing: needle) == wanted { return true }
            usleep(200_000)
        }
        return sessionRowValueExists(containing: needle) == wanted
    }

    /// The `collapsed` flag of one workspace node in a freshly built tree — nil when the workspace is
    /// EXPANDED (the field is omitted, expanded being the default), `true` when collapsed.
    private func workspaceCollapsed(_ id: String) throws -> Bool? {
        try workspaceNode(id)["collapsed"] as? Bool
    }

    /// The three focus read-back fields of one workspace, from a SINGLE `tree` snapshot so they can never be
    /// read across a mutation: the node's `focused` (the EFFECTIVE focus — the tree is filtered and this
    /// workspace is one of the workspaces it is filtered to) and `marked` (MEMBERSHIP in the marked set,
    /// filter applied or not), plus the tree TOP-LEVEL `workspaceFilter` (whether the filter applies at
    /// all). The documented invariant is `focused == marked && workspaceFilter`, which only one snapshot can
    /// check — and it is checked per MEMBER, since the set can hold several.
    private func focusState(ofWorkspace id: String) throws -> (focused: Bool?, marked: Bool?, filter: Bool?) {
        let root = try treeRoot()
        let nodes = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should carry workspaces")
        let node = try XCTUnwrap(nodes.first { $0["id"] as? String == id }, "workspace \(id) should be in the tree")
        return (node["focused"] as? Bool, node["marked"] as? Bool, root["workspaceFilter"] as? Bool)
    }

    // workspace.collapse/workspace.expand fold ONE workspace, and the `collapsed` read-back is driven by the
    // STORE, not by the live outline: the arm persists `Workspace.isExpanded` FIRST and only then pokes the
    // sidebar. Driving it with the sidebar HIDDEN is what proves that ordering — `WorkspaceSidebar` is an `if
    // store.sidebarVisible` branch of the split, so it is UNMOUNTED while hidden and a notification-only arm
    // (which is what sidebar.expand/sidebar.collapse still are) would answer ok and change nothing a script
    // can read. The notification leg cannot cover for a missing store write either: its handler brackets
    // expandItem/collapseItem in `suppressExpansionPersist`, so the outline never writes expansion back.
    // Re-showing the sidebar then proves the persisted state is what the re-mounted outline renders.
    func testWorkspaceCollapseExpandWritesStoreWithSidebarHidden() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        let firstWs = try XCTUnwrap((try workspaceNodes()).first, "should have a workspace")
        let firstWsID = try XCTUnwrap(firstWs["id"] as? String, "should have a seeded workspace id")
        let seededID = try XCTUnwrap((firstWs["sessions"] as? [[String: Any]])?.first?["id"] as? String,
                                     "should have a seeded session")
        XCTAssertNil(firstWs["collapsed"], "an expanded workspace must omit `collapsed`")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seededID)","args":{"name":"stay"}}"#)["ok"] as? Bool,
                       true, "renaming the seeded session should succeed")

        // a second workspace with its own session, so a collapse has something observable to fold away.
        let newWs = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"second"}}"#)
        let secondWsID = try XCTUnwrap((newWs["result"] as? [String: Any])?["id"] as? String, "workspace.new should return an id")
        let created = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(secondWsID)"}}"#)
        let newSessID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(newSessID)","args":{"name":"hidden"}}"#)["ok"] as? Bool,
                       true, "renaming the new session should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both rows should be present with both workspaces expanded")

        // the ACTIVE session must live in the FIRST workspace: the sidebar view-only expands the selected
        // session's owner when it reveals it, which would mask the collapse this test asserts.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seededID)"}"#)["ok"] as? Bool, true,
                       "selecting the seeded session should succeed")

        // hide the sidebar: the outline unmounts, so nothing is left to receive the poke.
        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar","args":{"mode":"hide"}}"#)["ok"] as? Bool, true,
                       "sidebar hide should succeed")
        XCTAssertTrue(app.staticTexts["session-row"].waitForNonExistence(timeout: 10),
                      "hiding the sidebar should remove the session rows (the outline is gone)")

        // the point of the test: with no sidebar mounted, only the store-first write can make this read back.
        let collapse = try sendCommand(#"{"cmd":"workspace.collapse","target":"\#(secondWsID)"}"#)
        XCTAssertEqual(collapse["ok"] as? Bool, true, "workspace.collapse should succeed: \(collapse)")
        XCTAssertEqual(((collapse["result"] as? [String: Any])?["id"] as? String)?.lowercased(),
                       secondWsID.lowercased(), "workspace.collapse should echo the resolved workspace id")
        XCTAssertEqual(try workspaceCollapsed(secondWsID), true,
                       "collapsed must read back with the sidebar hidden — the arm writes the store, not just the outline")
        XCTAssertNil(try workspaceCollapsed(firstWsID), "the untargeted workspace must stay expanded")

        // idempotent: setWorkspaceExpanded is delta-guarded, so a repeat is a clean no-op.
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.collapse","target":"\#(secondWsID)"}"#)["ok"] as? Bool, true,
                       "a repeated workspace.collapse should still succeed")
        XCTAssertEqual(try workspaceCollapsed(secondWsID), true, "a repeated collapse keeps the workspace collapsed")

        // re-showing the sidebar renders the PERSISTED state: the collapsed workspace's row stays folded.
        XCTAssertEqual(try sendCommand(#"{"cmd":"sidebar","args":{"mode":"show"}}"#)["ok"] as? Bool, true,
                       "sidebar show should succeed")
        XCTAssertTrue(pollSessionRowValue("stay", exists: true, timeout: 10), "the outline should re-mount with its rows")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "the collapsed workspace's rows should stay folded")
        XCTAssertFalse(sessionRowValueExists(containing: "hidden"), "the collapsed workspace's session should be hidden")

        // expand (sidebar now visible) clears the read-back AND drives the live outline.
        let expand = try sendCommand(#"{"cmd":"workspace.expand","target":"\#(secondWsID)"}"#)
        XCTAssertEqual(expand["ok"] as? Bool, true, "workspace.expand should succeed: \(expand)")
        XCTAssertNil(try workspaceCollapsed(secondWsID), "an expanded workspace omits `collapsed` again")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "expanding should restore the folded rows")
        XCTAssertTrue(sessionRowValueExists(containing: "hidden"), "the folded session's row should return")

        // an unknown target errors through the shared workspace resolver rather than silently no-opping.
        let bad = try sendCommand(#"{"cmd":"workspace.collapse","target":"deadbeef"}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an unknown workspace should fail: \(bad)")
        XCTAssertTrue((bad["error"] as? String ?? "").hasPrefix("no such workspace"),
                      "should report no such workspace, got: \(bad)")
    }

    // workspace.new --collapsed creates the workspace already folded, so a script can build one and fill it
    // with `session.new --no-select` without it popping open (a SELECTING create would view-only expand the
    // owner to reveal the new session, which is why the fill is a background one). Both legs are asserted:
    // the `collapsed` read-back AND the rendered outline, so the flag has to reach the sidebar and not just
    // the model — and expanding at the end proves the row was absent because it was FOLDED, not missing.
    func testWorkspaceNewCollapsedStaysFoldedWhileFilled() throws {
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "the seeded session should be the only row")

        let created = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"prebuilt","collapsed":true}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "workspace.new --collapsed should succeed: \(created)")
        let wsID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "workspace.new should return an id")
        XCTAssertEqual(try workspaceCollapsed(wsID), true, "--collapsed should create the workspace folded")

        // fill it in the background: the workspace must stay folded and its session's row must not appear.
        let session = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(wsID)","noSelect":true}}"#)
        XCTAssertEqual(session["ok"] as? Bool, true, "a background session.new should succeed: \(session)")
        let sessionID = try XCTUnwrap((session["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(sessionID)","args":{"name":"folded"}}"#)["ok"] as? Bool,
                       true, "renaming the background session should succeed")

        // the session really is in the model (both workspaces hold one) before asserting it is NOT rendered.
        XCTAssertTrue(pollSessionCounts([1, 1], timeout: 10), "the background session should land in the new workspace")
        XCTAssertEqual(try workspaceCollapsed(wsID), true, "a background add must not pop the workspace open")
        XCTAssertFalse(pollSessionRowValue("folded", exists: true, timeout: 3),
                       "the background session's row must stay folded away")

        // expanding reveals it — so the absence above was the collapse, not a session that never existed.
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.expand","target":"\#(wsID)"}"#)["ok"] as? Bool, true,
                       "workspace.expand should succeed")
        XCTAssertTrue(pollSessionRowValue("folded", exists: true, timeout: 10), "expanding should reveal the filled session")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both rows should be present once expanded")
    }

    // workspace.filter is the RE-APPLY leg of workspace.focus, and the reason the focus state is a marked
    // SET plus a separate flag. An INVOLUNTARY jump — here `session.select` of a session in ANOTHER
    // workspace, the same store path idle auto-follow, attention nav and a notification reveal take — drops
    // only the FILTER and KEEPS the set, so `workspace.filter on` returns to exactly the same workspaces;
    // before the split it nilled the focus outright and the focus was gone for good. Read back on all three
    // fields from one snapshot: `focused` (the EFFECTIVE focus, whose meaning is deliberately unchanged),
    // the node's `marked`, and the tree-level `workspaceFilter` — plus the visible tree, which is what those
    // fields describe. The closing block runs the same three-field read-back over a TWO-member set.
    func testWorkspaceFilterReappliesFocusAfterInvoluntaryJump() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        let firstWs = try XCTUnwrap((try workspaceNodes()).first, "should have a workspace")
        let firstWsID = try XCTUnwrap(firstWs["id"] as? String, "should have a seeded workspace id")
        let seededID = try XCTUnwrap((firstWs["sessions"] as? [[String: Any]])?.first?["id"] as? String,
                                     "should have a seeded session")
        XCTAssertNil(firstWs["marked"], "an unfocused workspace must omit `marked`")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seededID)","args":{"name":"stay"}}"#)["ok"] as? Bool,
                       true, "renaming the seeded session should succeed")

        let newWs = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"second"}}"#)
        let secondWsID = try XCTUnwrap((newWs["result"] as? [String: Any])?["id"] as? String, "workspace.new should return an id")
        let created = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(secondWsID)"}}"#)
        let newSessID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new should return an id")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(newSessID)","args":{"name":"hidden"}}"#)["ok"] as? Bool,
                       true, "renaming the new session should succeed")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "both rows should be present unfocused")

        // focus the first workspace with its own session selected, so nothing lifts the filter immediately.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seededID)"}"#)["ok"] as? Bool, true)
        let focus = try sendCommand(#"{"cmd":"workspace.focus","target":"\#(firstWsID)","args":{"mode":"on"}}"#)
        XCTAssertEqual(focus["ok"] as? Bool, true, "workspace.focus on should succeed: \(focus)")
        var state = try focusState(ofWorkspace: firstWsID)
        XCTAssertEqual(state.focused, true, "the focused workspace should report focused")
        XCTAssertEqual(state.marked, true, "…and be the marked one")
        XCTAssertEqual(state.filter, true, "…with the tree-level filter applied")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "the tree should collapse to the focused workspace")

        // the involuntary jump: selecting a session in ANOTHER workspace must reveal it, so the filter lifts.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(newSessID)"}"#)["ok"] as? Bool, true)
        state = try focusState(ofWorkspace: firstWsID)
        XCTAssertNil(state.focused, "an involuntary jump must lift the effective focus")
        XCTAssertEqual(state.marked, true, "…but must NOT forget which workspace was focused")
        XCTAssertEqual(state.filter, false, "…and the tree-level filter should read off")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "the whole tree should be visible again")

        // the leg that did not exist before: re-apply the surviving mark.
        let on = try sendCommand(#"{"cmd":"workspace.filter","args":{"mode":"on"}}"#)
        XCTAssertEqual(on["ok"] as? Bool, true, "workspace.filter on should succeed: \(on)")
        state = try focusState(ofWorkspace: firstWsID)
        XCTAssertEqual(state.focused, true, "re-enabling the filter should restore the focus")
        XCTAssertEqual(state.filter, true, "…and the tree-level filter")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "the tree should collapse back to the marked workspace")
        XCTAssertTrue(sessionRowValueExists(containing: "stay"), "the marked workspace's session should show")
        XCTAssertFalse(sessionRowValueExists(containing: "hidden"), "the other workspace's session should hide again")

        // an IN-SET select keeps the filter (only a cross-set jump lifts it), then jump out again so the
        // explicit unfocus below runs while the filter is ALREADY off.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seededID)"}"#)["ok"] as? Bool, true)
        XCTAssertEqual(try focusState(ofWorkspace: firstWsID).focused, true, "an in-set select must not lift the filter")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(newSessID)"}"#)["ok"] as? Bool, true)
        XCTAssertEqual(try focusState(ofWorkspace: firstWsID).marked, true, "the mark should survive the second jump")

        // an EXPLICIT unfocus drops the workspace from the SET even though the effective focus already reads
        // nil — un-marking is never gated on the filter being applied. It used to be gated on the effective
        // focus and silently kept the mark, so `workspace.filter on` resurrected a focus the user had just
        // dismissed. With the set now empty, the filter goes off with it.
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(firstWsID)","args":{"mode":"off"}}"#)["ok"] as? Bool,
                       true, "an explicit workspace.focus off should succeed")
        state = try focusState(ofWorkspace: firstWsID)
        XCTAssertNil(state.marked, "an explicit unfocus must forget the mark")
        XCTAssertNil(state.focused, "…so nothing is focused")
        XCTAssertEqual(state.filter, false, "…and the filter stays off")

        // with nothing marked there is nothing to filter to, so enabling is a clean no-op.
        let again = try sendCommand(#"{"cmd":"workspace.filter","args":{"mode":"on"}}"#)
        XCTAssertEqual(again["ok"] as? Bool, true, "workspace.filter on with nothing marked should still succeed: \(again)")
        state = try focusState(ofWorkspace: firstWsID)
        XCTAssertNil(state.marked, "a no-op enable must not invent a mark")
        XCTAssertNil(state.focused, "…and must not resurrect the dismissed focus")
        XCTAssertEqual(state.filter, false, "…so the tree-level filter stays off")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "the whole tree stays visible")

        // the same three-field read-back over a TWO-member set — the state the single-mark model could not
        // represent at all. Two adds mark BOTH workspaces and, since an add never touches the flag, leave the
        // filter off, so each reads marked-but-not-focused from its own snapshot.
        for id in [firstWsID, secondWsID] {
            XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(id)","args":{"mode":"add"}}"#)["ok"] as? Bool,
                           true, "workspace.focus add should succeed for \(id)")
        }
        for id in [firstWsID, secondWsID] {
            let member = try focusState(ofWorkspace: id)
            XCTAssertEqual(member.marked, true, "an add should mark \(id)")
            XCTAssertNil(member.focused, "…without an effective focus, since an add never applies the filter")
            XCTAssertEqual(member.filter, false, "…so the tree-level filter stays off")
        }

        // ONE workspace.filter on applies the WHOLE set: every member reports the effective focus, so the
        // invariant `focused == marked && workspaceFilter` holds on each of them, not just on a single mark.
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.filter","args":{"mode":"on"}}"#)["ok"] as? Bool, true,
                       "workspace.filter on with two members should succeed")
        for id in [firstWsID, secondWsID] {
            let member = try focusState(ofWorkspace: id)
            XCTAssertEqual(member.focused, true, "every member should report focused while the filter applies (\(id))")
            XCTAssertEqual(member.marked, true, "…and stay marked")
            XCTAssertEqual(member.filter, true, "…with the tree-level filter on")
        }

        // an invalid mode errors rather than half-applying.
        let bad = try sendCommand(#"{"cmd":"workspace.filter","args":{"mode":"sideways"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an invalid filter mode should error: \(bad)")
        XCTAssertTrue((bad["error"] as? String ?? "").contains("invalid workspace filter mode"),
                      "should report the invalid mode: \(bad)")
    }

    // `workspace.focus add` is the MEMBERSHIP mode: it marks a workspace and — the load-bearing part —
    // NEVER switches the filter on, so a working set is built row by row with the WHOLE tree still on
    // screen. An add that applied would collapse the tree onto the first member and hide the very rows the
    // next add needs. Both polarities of that rule are covered: with the filter OFF it stays off (here),
    // with it ON it stays on (testWorkspaceFocusHidesOtherWorkspaces). Then ONE `workspace.filter on`
    // applies the accumulated set and the NON-member workspace's rows disappear — which is also what makes
    // the "still on screen" assertions non-vacuous: those rows were filterable all along, they simply were
    // not being filtered.
    func testWorkspaceFocusAddBuildsMultiWorkspaceSet() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 10), "seeded session row")

        let firstWs = try XCTUnwrap((try workspaceNodes()).first, "should have a workspace")
        let firstWsID = try XCTUnwrap(firstWs["id"] as? String, "should have a seeded workspace id")
        let seededID = try XCTUnwrap((firstWs["sessions"] as? [[String: Any]])?.first?["id"] as? String,
                                     "should have a seeded session")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(seededID)","args":{"name":"alpha"}}"#)["ok"] as? Bool,
                       true, "renaming the seeded session should succeed")
        let secondWsID = try makeWorkspace(named: "second", withSession: "beta")
        let thirdWsID = try makeWorkspace(named: "third", withSession: "gamma")
        XCTAssertTrue(pollSessionRowCount(3, timeout: 10), "all three workspaces' rows should be present unfiltered")

        // select a session inside the set about to be built, so nothing lifts the filter when it applies
        // (session.new left `gamma` selected, and gamma's workspace is deliberately left OUT of the set).
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seededID)"}"#)["ok"] as? Bool, true,
                       "selecting the seeded session should succeed")

        // the first add MARKS without applying: the tree is untouched and workspaceFilter still reads false.
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(firstWsID)","args":{"mode":"add"}}"#)["ok"] as? Bool,
                       true, "the first workspace.focus add should succeed")
        var state = try focusState(ofWorkspace: firstWsID)
        XCTAssertEqual(state.marked, true, "an add should mark the workspace")
        XCTAssertNil(state.focused, "…but must not focus it")
        XCTAssertEqual(state.filter, false, "…and must not switch the filter on")
        XCTAssertTrue(pollSessionRowCount(3, timeout: 10), "one add must leave the whole tree on screen")

        // the second add widens the set, still without applying it — the row it targeted was only reachable
        // because the first add left the tree whole.
        XCTAssertEqual(try sendCommand(#"{"cmd":"workspace.focus","target":"\#(secondWsID)","args":{"mode":"add"}}"#)["ok"] as? Bool,
                       true, "the second workspace.focus add should succeed")
        for (label, id) in [("first", firstWsID), ("second", secondWsID)] {
            state = try focusState(ofWorkspace: id)
            XCTAssertEqual(state.marked, true, "the \(label) workspace should be marked")
            XCTAssertNil(state.focused, "…without an effective focus while the filter is off (\(label))")
            XCTAssertEqual(state.filter, false, "…and the tree-level filter should still read off (\(label))")
        }
        XCTAssertNil(try focusState(ofWorkspace: thirdWsID).marked, "the workspace never added must not be marked")
        XCTAssertTrue(pollSessionRowCount(3, timeout: 10), "two adds must leave the whole tree on screen")

        // ONE filter on applies the accumulated set: the two members stay, the non-member's rows disappear.
        let on = try sendCommand(#"{"cmd":"workspace.filter","args":{"mode":"on"}}"#)
        XCTAssertEqual(on["ok"] as? Bool, true, "workspace.filter on should succeed: \(on)")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 10), "applying the set should hide the non-member's rows")
        XCTAssertTrue(sessionRowValueExists(containing: "alpha"), "the first member's session should show")
        XCTAssertTrue(sessionRowValueExists(containing: "beta"), "the second member's session should show")
        XCTAssertFalse(sessionRowValueExists(containing: "gamma"), "the non-member's session should be hidden")

        // the three-field read-back with TWO members: both report focused AND marked, while a non-member
        // reports neither and still sees the tree-level flag (workspaceFilter is per-window, not per-workspace).
        for (label, id) in [("first", firstWsID), ("second", secondWsID)] {
            state = try focusState(ofWorkspace: id)
            XCTAssertEqual(state.focused, true, "the \(label) member should report focused while the filter applies")
            XCTAssertEqual(state.marked, true, "…and marked (\(label))")
            XCTAssertEqual(state.filter, true, "…with the tree-level filter on (\(label))")
        }
        let outsider = try focusState(ofWorkspace: thirdWsID)
        XCTAssertNil(outsider.focused, "a non-member must not report focused")
        XCTAssertNil(outsider.marked, "…nor marked")
        XCTAssertEqual(outsider.filter, true, "…while still reporting the tree-level filter it shares")

        // switching the filter off leaves the SET alone: BOTH members keep `marked`, both lose `focused`,
        // and the whole tree comes back — the state one `workspace.filter on` returns from.
        let off = try sendCommand(#"{"cmd":"workspace.filter","args":{"mode":"off"}}"#)
        XCTAssertEqual(off["ok"] as? Bool, true, "workspace.filter off should succeed: \(off)")
        for (label, id) in [("first", firstWsID), ("second", secondWsID)] {
            state = try focusState(ofWorkspace: id)
            XCTAssertEqual(state.marked, true, "switching the filter off must not un-mark the \(label) member")
            XCTAssertNil(state.focused, "…but the effective focus goes with the filter (\(label))")
            XCTAssertEqual(state.filter, false, "…and the tree-level filter reads off (\(label))")
        }
        XCTAssertTrue(pollSessionRowCount(3, timeout: 10), "the whole tree should be back with the filter off")
    }

    /// Creates a workspace named `name` holding one session renamed `session`, returning the workspace id —
    /// the three-command preamble the multi-workspace focus e2e needs twice over. Note `session.new` SELECTS
    /// the new session, so a caller that cares about the active session re-selects afterwards.
    private func makeWorkspace(named name: String, withSession session: String) throws -> String {
        let created = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"\#(name)"}}"#)
        let wsID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String,
                                 "workspace.new should return an id")
        let made = try sendCommand(#"{"cmd":"session.new","args":{"workspace":"\#(wsID)"}}"#)
        let sessionID = try XCTUnwrap((made["result"] as? [String: Any])?["id"] as? String,
                                      "session.new should return an id")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.rename","target":"\#(sessionID)","args":{"name":"\#(session)"}}"#)["ok"] as? Bool,
                       true, "renaming \(session) should succeed")
        return wsID
    }

    // session.status sets a session's agent indicator: a valid state returns ok + the resolved id, an
    // unknown state returns the literal `invalid status` error, and an unknown target is not-found.
    func testSessionStatusSetsIndicator() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // a valid state with a blink flag succeeds and echoes the resolved id.
        let ok = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active","blink":true}}"#)
        XCTAssertEqual(ok["ok"] as? Bool, true, "session.status active should succeed: \(ok)")
        let result = try XCTUnwrap(ok["result"] as? [String: Any], "session.status should carry a result")
        XCTAssertEqual((result["id"] as? String)?.lowercased(), seeded.lowercased(),
                       "session.status should return the resolved session id: \(ok)")

        // an unknown state returns the literal guard string the arm emits.
        let bad = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"bogus"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an unknown status should fail: \(bad)")
        XCTAssertEqual(bad["error"] as? String, "invalid status", "should report invalid status: \(bad)")

        // an unknown target is the structured not-found error (mirrors testUnknownTargetErrors).
        let unknown = try sendCommand(#"{"cmd":"session.status","target":"deadbeef","args":{"status":"active"}}"#)
        XCTAssertEqual(unknown["ok"] as? Bool, false, "an unknown target should fail: \(unknown)")
        let error = try XCTUnwrap(unknown["error"] as? String, "an unknown target should carry an error")
        XCTAssertTrue(error.hasPrefix("no such session"), "should report no such session, got: \(error)")
    }

    func testSessionStatusSoundValidatesName() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // reads the seeded session's current status from a fresh tree (nil when idle/absent).
        func currentStatus() throws -> String? {
            let t = try sendCommand(#"{"cmd":"tree"}"#)
            let r = try XCTUnwrap(t["result"] as? [String: Any])
            let ws = try XCTUnwrap((r["tree"] as? [String: Any])?["workspaces"] as? [[String: Any]])
            let all = ws.flatMap { $0["sessions"] as? [[String: Any]] ?? [] }
            return all.first { ($0["id"] as? String) == seeded }?["status"] as? String
        }

        // the default-beep keyword resolves and the command succeeds.
        let ok = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active","sound":"default"}}"#)
        XCTAssertEqual(ok["ok"] as? Bool, true, "session.status --sound default should succeed: \(ok)")

        // establish a known baseline, then try to set a DIFFERENT status with an unknown sound.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"completed"}}"#)["ok"] as? Bool, true)
        XCTAssertEqual(try currentStatus(), "completed", "baseline status should be completed")

        let bad = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active","sound":"NoSuchSoundXYZ"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an unknown sound should fail: \(bad)")
        let error = try XCTUnwrap(bad["error"] as? String, "an unknown sound should carry an error")
        XCTAssertTrue(error.hasPrefix("unknown sound: NoSuchSoundXYZ"), "should report the unknown sound, got: \(error)")

        // the rejected call must NOT have changed the status — validation happens before the mutation.
        XCTAssertEqual(try currentStatus(), "completed", "an unknown sound must leave the status unchanged")
    }

    // session.status --color sets a per-call glyph tint. The tint itself is NOT accessibility-observable
    // (glyph color, like the cursor's solid/hollow state, isn't in the AX tree — covered host-free +
    // manual), so this drives the command path end-to-end: a valid #rrggbb applies the status, and a
    // malformed color is rejected before the mutation and leaves the status unchanged.
    func testSessionStatusColorValidatesHex() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        func currentStatus() throws -> String? {
            let t = try sendCommand(#"{"cmd":"tree"}"#)
            let r = try XCTUnwrap(t["result"] as? [String: Any])
            let ws = try XCTUnwrap((r["tree"] as? [String: Any])?["workspaces"] as? [[String: Any]])
            let all = ws.flatMap { $0["sessions"] as? [[String: Any]] ?? [] }
            return all.first { ($0["id"] as? String) == seeded }?["status"] as? String
        }

        // a valid #rrggbb applies the status and shows the glyph. NOTE: the `"#ff0000"` value contains the
        // `"#` sequence, which would close a `#"..."#` raw string early, so this line uses the `##"..."##`
        // delimiter (and `\##(seeded)` interpolation) — the rest of the file's `#"..."#` JSON has no `#`.
        let ok = try sendCommand(##"{"cmd":"session.status","target":"\##(seeded)","args":{"status":"blocked","color":"#ff0000"}}"##)
        XCTAssertEqual(ok["ok"] as? Bool, true, "session.status --color #ff0000 should succeed: \(ok)")
        XCTAssertEqual(try currentStatus(), "blocked", "the status should be applied")
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12),
                      "the status glyph should appear on the session's row")

        // a malformed color is rejected before the mutation.
        let bad = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active","color":"nope"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "a malformed color should fail: \(bad)")
        XCTAssertEqual(bad["error"] as? String, "invalid color (expected #rrggbb)", "should report the invalid color: \(bad)")

        // the rejected call must NOT have changed the status — validation happens before the mutation.
        XCTAssertEqual(try currentStatus(), "blocked", "an invalid color must leave the status unchanged")
    }

    // the agent-status icon shows on every non-idle session, the selected one INCLUDED — there is no
    // visibility gate. Set active on a non-selected session → the icon appears; select that session → it
    // STAYS (active is keep-state); set completed --auto-reset on a non-selected session → it shows, then
    // VISITING (selecting) it clears the auto-reset flash.
    func testAgentStatusIconShowsRegardlessOfSelectionAndAutoResetClears() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // a second session takes focus, leaving the seeded one realized but non-selected.
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let createdResult = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let secondID = try XCTUnwrap(createdResult["id"] as? String, "session.new should return the new id")
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the new session should land")

        // negative baseline: no status set yet, so no agent-status icon exists on any row.
        XCTAssertTrue(app.staticTexts["agent-status"].waitForNonExistence(timeout: 5),
                      "no agent-status icon should exist before any status is set")

        // set active on the non-selected seeded session: the icon appears.
        let status = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active"}}"#)
        XCTAssertEqual(status["ok"] as? Bool, true, "session.status active should succeed: \(status)")
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12),
                      "the status icon should appear on the session's row")

        // selecting that session KEEPS the icon — active is keep-state and there is no visibility gate.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seeded)"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 5),
                      "the active status icon stays on the selected session (no visibility gate)")

        // completed --auto-reset on the now non-selected session shows, then VISITING it clears it.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(secondID)"}"#)["ok"] as? Bool, true)
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"completed","autoReset":true}}"#)["ok"] as? Bool, true)
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12),
                      "completed --auto-reset should show on the non-selected session")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seeded)"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(app.staticTexts["agent-status"].waitForNonExistence(timeout: 12),
                      "visiting a completed --auto-reset session should clear its icon")
    }

    // typing into a session flagged for your attention (`blocked` or `completed`) clears the glyph — the
    // input-driven clear. blocked covers the Esc-decline case Claude Code fires no hook for; completed clears
    // the finished flash once you re-engage. wired off GhosttySurfaceView.keyDown, so it MUST be driven by the
    // real keyboard: `session.type`/inject calls ghostty_surface_key directly, bypassing keyDown.
    func testTypingClearsBlockedOrCompletedStatus() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // press a real key into the focused terminal until the glyph clears. keyboard focus return can be
        // async, so retry (mirrors the marker-poll retry idiom).
        func typeUntilGlyphCleared() -> Bool {
            for _ in 0..<8 {
                app.typeKey(.escape, modifierFlags: [])
                if app.staticTexts["agent-status"].waitForNonExistence(timeout: 2) { return true }
            }
            return false
        }

        // both attention states clear on a keystroke; active would NOT (agent still working), idle has no glyph.
        for state in ["blocked", "completed"] {
            let set = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"\#(state)"}}"#)
            XCTAssertEqual(set["ok"] as? Bool, true, "session.status \(state) should succeed: \(set)")
            XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12),
                          "\(state) should show the agent-status glyph")
            XCTAssertTrue(typeUntilGlyphCleared(), "typing into a \(state) session should clear its glyph")
        }
    }

    // an `active` glyph clears ONLY on an interrupt keystroke. Ctrl-C is an interrupt just like Esc — Claude
    // Code and most TUIs treat it as Esc for dismissing a pending prompt — so it must drop the stale glyph
    // where ordinary typing (host-free tested) does not. covers the app-side `isInterruptKeystroke` wiring
    // the host-free `clearedByKeystroke` cannot reach.
    func testCtrlCClearsActiveStatus() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        let set = try sendCommand(#"{"cmd":"session.status","target":"\#(seeded)","args":{"status":"active"}}"#)
        XCTAssertEqual(set["ok"] as? Bool, true, "session.status active should succeed: \(set)")
        XCTAssertTrue(app.staticTexts["agent-status"].waitForExistence(timeout: 12),
                      "active should show the agent-status glyph")

        // Ctrl-C into the focused terminal must clear it. keyboard focus return can be async, so retry.
        for _ in 0..<8 {
            app.typeKey("c", modifierFlags: .control)
            if app.staticTexts["agent-status"].waitForNonExistence(timeout: 2) { return }
        }
        XCTFail("Ctrl-C into an active session should clear its glyph")
    }

    // the General → "Show notification badges" toggle gates the red count pill's RENDERING (the count
    // keeps tracking either way): fire a notification on a non-selected session so notify-badge shows,
    // toggle the setting off → the badge hides, toggle on → it reappears with the same count.
    func testNotificationBadgeToggleHidesAndShowsBadge() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // a second session takes focus, leaving the seeded one non-selected so its badge persists.
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.new"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the new session should land")

        // notify (no focus-suppression) bumps the non-selected session's unseen count → the badge shows.
        let notified = try sendCommand(#"{"cmd":"notify","target":"\#(seeded)","args":{"body":"hi"}}"#)
        XCTAssertEqual(notified["ok"] as? Bool, true, "notify should succeed: \(notified)")
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForExistence(timeout: 12),
                      "the count badge should appear on the non-selected session's row")

        // turn the count badges off → the pill hides (render-only; the count keeps tracking).
        toggleNotificationBadges()
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForNonExistence(timeout: 12),
                      "hiding the badge setting should hide the count pill")

        // turn it back on → the pill reappears with the still-tracked count.
        toggleNotificationBadges()
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForExistence(timeout: 12),
                      "re-enabling the badge setting should show the count pill again")
    }

    // session.seen clears a session's unseen badge WITHOUT changing the selection/focus — the focus-free
    // counterpart to notify. Fire notify on a non-selected session so the badge + tree `unseen` read-back
    // show, then session.seen clears both while the selection stays on the other session.
    func testSessionSeenClearsBadgeWithoutFocus() throws {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(treeResult["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        let seeded = try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")

        // a second session takes focus, leaving the seeded one non-selected so its badge persists.
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        XCTAssertEqual(created["ok"] as? Bool, true)
        let newSession = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new returns the new id")
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the new session should land")

        // notify (no focus-suppression) bumps the non-selected session's unseen count → the badge shows.
        let notified = try sendCommand(#"{"cmd":"notify","target":"\#(seeded)","args":{"body":"hi"}}"#)
        XCTAssertEqual(notified["ok"] as? Bool, true, "notify should succeed: \(notified)")
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForExistence(timeout: 12),
                      "the count badge should appear on the non-selected session's row")

        // the tree read-back surfaces the unseen count and the new session is the active one.
        XCTAssertEqual(unseenCount(forSession: seeded), 1, "tree should report the seeded session's unseen count")
        XCTAssertEqual(activeNodeID(), newSession, "the new session should be the active selection")

        // session.seen clears the badge; it targets the NON-selected session and returns its id.
        let seen = try sendCommand(#"{"cmd":"session.seen","target":"\#(seeded)"}"#)
        XCTAssertEqual(seen["ok"] as? Bool, true, "session.seen should succeed: \(seen)")
        XCTAssertEqual((seen["result"] as? [String: Any])?["id"] as? String, seeded, "session.seen echoes the target id")
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForNonExistence(timeout: 12),
                      "session.seen should clear the count pill")

        // the clear is focus-free: the selection is unchanged and the tree no longer reports unseen.
        XCTAssertEqual(activeNodeID(), newSession, "session.seen must NOT change the active selection")
        XCTAssertNil(unseenCount(forSession: seeded), "the seeded session's unseen count should be cleared (omitted)")

        // idempotent: a second seen on an already-clear session is ok AND a genuine no-op (end-state holds).
        let again = try sendCommand(#"{"cmd":"session.seen","target":"\#(seeded)"}"#)
        XCTAssertEqual(again["ok"] as? Bool, true, "session.seen is idempotent when the badge is already zero")
        XCTAssertNil(unseenCount(forSession: seeded), "a repeat seen keeps the badge cleared")
        XCTAssertEqual(activeNodeID(), newSession, "a repeat seen must not change the active selection")

        // an unknown target errors through the shared resolver, like the other session.* commands.
        let bad = try sendCommand(#"{"cmd":"session.seen","target":"deadbeef"}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "session.seen with an unknown target should fail")
        XCTAssertTrue((bad["error"] as? String ?? "").hasPrefix("no such session"),
                      "should report no such session, got: \(bad)")
    }

    // returning rook to the foreground on a session that's on screen clears that session's badge — the
    // same "you've seen it" clear a focus transition does. Reproduced across two windows because re-keying
    // a window fires the SAME NSWindow.didBecomeKey path as app reactivation, without the flaky
    // background-the-app dance: open a second window so the seeded session's window loses key, notify the
    // seeded session so its badge shows, then re-select its window. window.select does NOT re-select the
    // session, so only the didBecomeKey → onFocusChange clear can drop the badge — a genuine regression
    // for #155 (the badge used to stay stuck until you switched sessions and back).
    func testRefocusingWindowClearsOnScreenSessionBadge() throws {
        let seeded = try activeSessionID()

        // capture the seeded window's id before opening a second one — window.select needs it to re-key
        // the ORIGINAL window (--target defaults to the active window, which becomes the new one).
        let windows = try XCTUnwrap(
            (try sendCommand(#"{"cmd":"window.list"}"#)["result"] as? [String: Any])?["windows"] as? [[String: Any]],
            "window.list should carry windows")
        let firstWindow = try XCTUnwrap(windows.first?["id"] as? String, "should have the seeded window id")

        // a second window materializes and takes key, so the seeded session's window is no longer key (its
        // focused pane keeps first responder per-window, but the window isn't key — the bug's precondition).
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.new"}"#)["ok"] as? Bool, true)
        let appeared = Date().addingTimeInterval(10)
        while Date() < appeared, app.windows.count < 2 { usleep(200_000) }
        XCTAssertGreaterThanOrEqual(app.windows.count, 2, "the second window should materialize and take key")

        // notify (no focus-suppression) bumps the seeded session's badge while its window is unkeyed.
        let notified = try sendCommand(#"{"cmd":"notify","target":"\#(seeded)","args":{"body":"hi"}}"#)
        XCTAssertEqual(notified["ok"] as? Bool, true, "notify should succeed: \(notified)")
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForExistence(timeout: 12),
                      "the badge should appear on the seeded session's row")

        // re-key the seeded session's window (the cmd-tab / reactivating-click equivalent). No session
        // switch happens, so a passing clear here can only come from the didBecomeKey → onFocusChange path.
        // window.select can return before the window is actually key under XCUITest, so wait for it to report
        // active before asserting the didBecomeKey-driven clear.
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.select","target":"\#(firstWindow)"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(pollWindowActive(firstWindow, timeout: 12), "window 1 should become key again after window.select")
        XCTAssertTrue(app.staticTexts["notify-badge"].waitForNonExistence(timeout: 12),
                      "refocusing the window should clear the on-screen session's badge without a session switch")
    }

    // the refocus clear is gated on liveFocus, so it clears ONLY the focused pane's session — never other
    // badged sessions in the same window. This is the inverse of testRefocusingWindowClearsOnScreenSessionBadge:
    // a regression that dropped the liveFocus guard (clearing every session's badge on didBecomeKey) would
    // still pass the positive test but fail this one. The seeded session holds focus while a SECOND session
    // carries the badge; refocus lands on the seeded (focused) session, so the second session's pill must
    // survive. The badged session is deliberately the non-focused one so its badge is tree-verifiable both
    // before and after the refocus (a focused session in a key window can't hold an unseen badge).
    func testRefocusingWindowKeepsNonFocusedSessionBadge() throws {
        let seeded = try activeSessionID()
        let firstWindow = try XCTUnwrap(
            ((try sendCommand(#"{"cmd":"window.list"}"#)["result"] as? [String: Any])?["windows"] as? [[String: Any]])?
                .first?["id"] as? String, "should have the seeded window id")

        // add a second session, then re-select the seeded one so IT holds focus and the second is the
        // non-focused session whose badge the refocus must leave alone.
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let other = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String, "session.new returns the new id")
        XCTAssertTrue(pollSessionCount(2, timeout: 10), "the second session should land")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(seeded)"}"#)["ok"] as? Bool, true)

        // badge the NON-focused second session and confirm the badge landed — an unfocused session isn't
        // "seen", so its badge persists and is readable via the frontmost tree while window 1 is frontmost.
        XCTAssertEqual(try sendCommand(#"{"cmd":"notify","target":"\#(other)","args":{"body":"hi"}}"#)["ok"] as? Bool, true)
        XCTAssertTrue(pollUnseen(other, equals: 1, timeout: 12), "the non-focused session should carry a badge before the refocus")

        // a second window materializes and takes key, so window 1 is no longer key.
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.new"}"#)["ok"] as? Bool, true)
        let appeared = Date().addingTimeInterval(10)
        while Date() < appeared, app.windows.count < 2 { usleep(200_000) }
        XCTAssertGreaterThanOrEqual(app.windows.count, 2, "the second window should materialize and take key")

        // re-key window 1 (the cmd-tab refocus). Focus lands on the SEEDED session, never the badged one, so
        // the non-focused session's pill must survive. Wait for the window to actually become key first.
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.select","target":"\#(firstWindow)"}"#)["ok"] as? Bool, true)
        XCTAssertTrue(pollWindowActive(firstWindow, timeout: 12), "window 1 should become key again after window.select")
        XCTAssertEqual(unseenCount(forSession: other), 1, "a non-focused session's badge must survive the refocus")
    }

    // polls window.list until the window with `id` reports active (frontmost/key), or times out. Under
    // XCUITest a window.select response can arrive before the window is actually key, so tests wait on this
    // before asserting a didBecomeKey-driven effect. Returns true on match, false on timeout.
    private func pollWindowActive(_ id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = (try? sendCommand(#"{"cmd":"window.list"}"#))?["result"] as? [String: Any],
               let windows = result["windows"] as? [[String: Any]],
               windows.contains(where: { ($0["id"] as? String)?.lowercased() == id.lowercased() && $0["active"] as? Bool == true }) {
                return true
            }
            usleep(200_000)
        }
        return false
    }

    // polls the frontmost window's tree until the given session's unseen count equals `expected` (nil = the
    // badge is cleared / omitted), returning true on match or false on timeout.
    private func pollUnseen(_ id: String, equals expected: Int?, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if unseenCount(forSession: id) == expected { return true }
            usleep(200_000)
        }
        return unseenCount(forSession: id) == expected
    }

    // the unseen badge count reported for a session in the current tree, or nil when omitted (zero).
    private func unseenCount(forSession id: String) -> Int? {
        guard let result = (try? sendCommand(#"{"cmd":"tree"}"#))?["result"] as? [String: Any],
              let root = result["tree"] as? [String: Any],
              let workspaces = root["workspaces"] as? [[String: Any]] else { return nil }
        for workspace in workspaces {
            for session in (workspace["sessions"] as? [[String: Any]] ?? []) where session["id"] as? String == id {
                return session["unseen"] as? Int
            }
        }
        return nil
    }

    // the id of the active (selected) session in the current tree, or nil when none is selected.
    // (distinct from ControlAPITestCase.activeSessionID(), which returns the first session unconditionally.)
    private func activeNodeID() -> String? {
        guard let result = (try? sendCommand(#"{"cmd":"tree"}"#))?["result"] as? [String: Any],
              let root = result["tree"] as? [String: Any],
              let workspaces = root["workspaces"] as? [[String: Any]] else { return nil }
        for workspace in workspaces {
            for session in (workspace["sessions"] as? [[String: Any]] ?? []) where session["active"] as? Bool == true {
                return session["id"] as? String
            }
        }
        return nil
    }

    // notify posts a banner for the active session; a missing body errors.
    func testNotifySend() throws {
        let ok = try sendCommand(#"{"cmd":"notify","target":"active","args":{"body":"hello","title":"Test"}}"#)
        XCTAssertEqual(ok["ok"] as? Bool, true, "notify with a body should succeed: \(ok)")

        let noBody = try sendCommand(#"{"cmd":"notify","target":"active"}"#)
        XCTAssertEqual(noBody["ok"] as? Bool, false, "notify without a body should fail: \(noBody)")
        XCTAssertTrue((noBody["error"] as? String ?? "").contains("requires a body"), "should report missing body: \(noBody)")
    }

    /// Opens Settings (Cmd+,), switches to General, and clicks the "Show notification badges" toggle.
    /// Retries the tab/toggle click each tick (a stale or half-open Settings window can drop the first
    /// click), mirroring SettingsUITests' robust `settingsControl`.
    private func toggleNotificationBadges() {
        let toggle = app.descendants(matching: .any).matching(identifier: "settings-notification-badges").firstMatch
        let tabButton = app.buttons["Notifications"].firstMatch
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if toggle.exists, toggle.isHittable { toggle.click(); return }
            if tabButton.exists, tabButton.isHittable {
                tabButton.click()
            } else {
                app.typeKey(",", modifierFlags: .command) // settings not open yet (or lost) — (re)open
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("the notification-badges toggle never became hittable")
    }
}
