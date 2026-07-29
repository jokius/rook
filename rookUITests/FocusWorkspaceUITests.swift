import XCTest

/// Real UI tests for the workspace focus filter. These launch the actual app and drive the sidebar
/// through the accessibility API — the behavioral coverage the host-free `rookCore` unit tests can't
/// reach (the focus-filtered tree data source + the bottom-bar filter toggle live in
/// `WorkspaceSidebar.Coordinator` / `WindowContentView`).
///
/// Accessibility-tree facts these queries rely on (shared with SidebarUITests/FlaggedViewUITests):
/// - a session row exposes its name as a StaticText `value` under the `session-row` identifier;
/// - a workspace header exposes its name as a StaticText `label`;
/// - the bottom-bar filter control is a button with identifier `focus-filter-toggle`, DISABLED while the
///   marked set is empty, whose accessibility VALUE is `on`/`off`. That value is the ONLY accessible read
///   of whether the filter applies: the `focus-pill` it replaced rendered the single focused workspace's
///   name and existed only while focused, so its mere ABSENCE used to report the state — an assertion
///   shape that goes silently vacuous the moment the element is gone, which is why every pill assertion
///   here was replaced rather than deleted;
/// - the workspace row's context menu carries BOTH focus gestures: "Focus"/"Unfocus" REPLACES the marked
///   set with that one workspace and applies the filter (so it reads "Unfocus" only while that workspace
///   is the SOLE member of an APPLIED filter), while "Add to Focus"/"Remove from Focus" edits MEMBERSHIP
///   alone and never touches the filter flag.
@MainActor
final class FocusWorkspaceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        // hermetic state: a fresh temp dir per test so the app seeds exactly one "workspace 1" + one
        // session, and we never touch the real workspaces.json.
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rook-uitest-\(UUID().uuidString)", isDirectory: true)
        app = XCUIApplication()
        app.launchEnvironment["ROOK_STATE_DIR"] = stateDir.path
        app.launchForUITest()
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    /// End-to-end single-workspace focus: seed two workspaces (workspace 1 holding the visible session,
    /// workspace 2 empty), focus workspace 2 via its header's context menu — the OTHER workspace's header
    /// AND its session row leave the AX tree while the filter toggle flips to `on` — then click the toggle
    /// to SUSPEND the filter and click it again to re-apply it.
    ///
    /// The suspend/re-apply pair is the point: the toggle stays ENABLED while the filter is off, and one
    /// more click collapses the tree back to the SAME workspace — proof the marked set survived. Under the
    /// old single-focus model there was no such state (unfocusing forgot the workspace outright, and the
    /// pill that reported the focus vanished with it), so this is the assertion block that replaced it.
    ///
    /// Focusing the (empty) other workspace is what makes a *visible* session row (workspace 1's, which is
    /// expanded because it holds the selection) leave the AX tree — a non-member workspace's own sessions
    /// are collapsed, so only the filtered-away workspace's rows are reliably observable as disappearing.
    func testFocusWorkspaceHidesOthersAndFilterToggleKeepsTheMark() throws {
        // workspace 1: [visible] (seeded, selected, expanded); workspace 2: empty.
        XCTAssertTrue(sessionRow().waitForExistence(timeout: 20), "seeded session should exist")
        renameSeededSession(to: "visible")
        addWorkspace(expecting: "workspace 2")

        // nothing marked: the visible session row and both workspace headers are present, and the filter
        // toggle reports `off` AND is DISABLED — with an empty set there is nothing to filter to, which is
        // exactly the state the store refuses to enable.
        XCTAssertTrue(sessionRow(named: "visible").waitForExistence(timeout: 8), "visible row should exist unfiltered")
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForExistence(timeout: 5), "workspace 1 header should exist")
        XCTAssertTrue(pollFilterToggle(value: "off", enabled: false),
                      "an empty marked set must leave the filter toggle off AND disabled")

        // focus workspace 2 via its header's context menu: the set becomes {workspace 2} and the filter is
        // applied in the same gesture, so workspace 1 (header + its visible session row) leaves the AX tree.
        rowMenu(ofWorkspace: "workspace 2", click: "Focus")
        XCTAssertTrue(sessionRow(named: "visible").waitForNonExistence(timeout: 8),
                      "the other workspace's session row should leave the AX tree while the filter applies")
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForNonExistence(timeout: 5),
                      "the other workspace's header should leave the AX tree while the filter applies")
        XCTAssertTrue(app.staticTexts["workspace 2"].waitForExistence(timeout: 5),
                      "the marked workspace's header should remain")
        XCTAssertTrue(pollFilterToggle(value: "on", enabled: true),
                      "Focus should apply the filter, which the toggle reports as on")

        // clicking the toggle SUSPENDS the filter: the whole tree comes back and the toggle reads `off` —
        // but it stays ENABLED, because workspace 2 is still marked. (Enabled-vs-disabled here is the only
        // accessible difference between "marked but not filtering" and "nothing marked at all".)
        clickFilterToggle()
        XCTAssertTrue(sessionRow(named: "visible").waitForExistence(timeout: 8),
                      "suspending the filter should restore the other workspace's session row")
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForExistence(timeout: 5),
                      "suspending the filter should restore the other workspace's header")
        XCTAssertTrue(pollFilterToggle(value: "off", enabled: true),
                      "suspending the filter must KEEP the marked set, so the toggle stays enabled")

        // …and one more click re-applies that same set — the proof the mark survived the suspension.
        clickFilterToggle()
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForNonExistence(timeout: 8),
                      "re-applying the filter should collapse the tree back to the marked workspace")
        XCTAssertTrue(app.staticTexts["workspace 2"].waitForExistence(timeout: 5),
                      "the still-marked workspace should be the one the tree collapses back to")
        XCTAssertTrue(pollFilterToggle(value: "on", enabled: true), "the toggle should report the filter on again")
    }

    /// End-to-end MULTI-workspace focus through the row menu's "Add to Focus": mark two of three
    /// workspaces one at a time, apply the set with one toggle click, then remove the members one at a
    /// time.
    ///
    /// The load-bearing assertion is that an ADD never switches the filter on — after both adds the whole
    /// tree is still on screen and the toggle still reads `off` (merely ENABLED). An add that applied
    /// would collapse the tree onto the first member and hide the very row the second add needs. The
    /// closing removals pin the other half: dropping one member of two leaves the rest marked and
    /// filtering, and dropping the last one disables the filter as the set empties.
    func testAddToFocusBuildsMultiWorkspaceSetWithoutApplyingTheFilter() throws {
        XCTAssertTrue(sessionRow().waitForExistence(timeout: 20), "seeded session should exist")
        renameSeededSession(to: "visible")
        addWorkspace(expecting: "workspace 2")
        addWorkspace(expecting: "workspace 3")

        // build the set row by row. The toggle arming (disabled → enabled) is what reports the membership;
        // the VALUE staying `off` across both adds is what reports that marking never applies the filter.
        rowMenu(ofWorkspace: "workspace 1", click: "Add to Focus")
        XCTAssertTrue(pollFilterToggle(value: "off", enabled: true),
                      "the first add should arm the toggle WITHOUT applying the filter")
        rowMenu(ofWorkspace: "workspace 2", click: "Add to Focus")
        XCTAssertTrue(pollFilterToggle(value: "off", enabled: true),
                      "a second add must still not apply the filter")

        // with the filter off the WHOLE tree is on screen — including the non-member workspace 3, whose
        // row is what a wrongly-enabling add would have hidden.
        for header in ["workspace 1", "workspace 2", "workspace 3"] {
            XCTAssertTrue(app.staticTexts[header].waitForExistence(timeout: 5),
                          "\(header) should still be on screen while the filter is off")
        }
        XCTAssertTrue(sessionRow(named: "visible").waitForExistence(timeout: 5),
                      "the member workspace's session row should still be on screen while the filter is off")

        // ONE toggle click applies the accumulated set: both members stay, the non-member leaves. This is
        // also what makes the presence assertions above non-vacuous — workspace 3's row was filterable all
        // along, it simply was not being filtered.
        clickFilterToggle()
        XCTAssertTrue(app.staticTexts["workspace 3"].waitForNonExistence(timeout: 8),
                      "applying the set should hide the workspace that was never marked")
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForExistence(timeout: 5), "member workspace 1 should stay")
        XCTAssertTrue(app.staticTexts["workspace 2"].waitForExistence(timeout: 5), "member workspace 2 should stay")
        XCTAssertTrue(sessionRow(named: "visible").waitForExistence(timeout: 5),
                      "a member workspace's session row should stay while the filter applies")
        XCTAssertTrue(pollFilterToggle(value: "on", enabled: true), "the toggle should report the applied filter")

        // removing ONE member of two drops just that workspace and leaves the rest marked and filtering —
        // the "Remove from Focus" label is itself the assertion that the row menu tracked the membership.
        rowMenu(ofWorkspace: "workspace 2", click: "Remove from Focus")
        XCTAssertTrue(app.staticTexts["workspace 2"].waitForNonExistence(timeout: 8),
                      "the removed workspace should leave the tree, since the filter still applies")
        XCTAssertTrue(app.staticTexts["workspace 1"].waitForExistence(timeout: 5),
                      "the surviving member should still be visible")
        XCTAssertTrue(app.staticTexts["workspace 3"].waitForNonExistence(timeout: 5),
                      "the never-marked workspace should still be filtered out")
        XCTAssertTrue(pollFilterToggle(value: "on", enabled: true),
                      "removing one of two members must leave the filter applied")

        // removing the LAST member empties the set, which disables the filter: the full tree returns and
        // the toggle goes back to off + disabled — the `enabled && empty` state is unreachable.
        rowMenu(ofWorkspace: "workspace 1", click: "Remove from Focus")
        XCTAssertTrue(pollFilterToggle(value: "off", enabled: false),
                      "emptying the marked set must disable the filter AND the toggle")
        for header in ["workspace 1", "workspace 2", "workspace 3"] {
            XCTAssertTrue(app.staticTexts[header].waitForExistence(timeout: 8),
                          "\(header) should return once the set empties")
        }
    }

    // MARK: - Actions

    /// Right-clicks the named workspace header and clicks the context-menu item titled `title` — the one
    /// entry point for all four focus gestures ("Focus"/"Unfocus", "Add to Focus"/"Remove from Focus"), so
    /// a test that asks for "Remove from Focus" also asserts the row menu flipped its label (the item
    /// simply never becomes hittable otherwise).
    private func rowMenu(ofWorkspace name: String, click title: String) {
        let header = app.staticTexts[name]
        XCTAssertTrue(header.waitForHittable(timeout: 8), "\(name) header should be hittable to open its menu")
        header.rightClick()
        let item = presentedMenuItem(title)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(title) menu item should appear on \(name)'s row menu")
        item.click()
    }

    /// Clicks the bottom-bar filter toggle, waiting for it to be hittable first (it is disabled — and so
    /// un-hittable — whenever the marked set is empty).
    private func clickFilterToggle() {
        let toggle = filterToggle()
        XCTAssertTrue(toggle.waitForHittable(timeout: 8), "the focus-filter toggle should be hittable")
        toggle.click()
    }

    /// Adds a new (empty) workspace via the bottom-bar add-workspace button and waits for its header.
    private func addWorkspace(expecting name: String) {
        app.buttons["New Workspace"].click()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 8), "\(name) should appear")
    }

    /// Renames the ONLY session row — the seeded one — to `newName` via the inline editor (double-click to
    /// enter edit mode, retrying — far more reliable than the context menu when a bottom-bar menu was just
    /// dismissed).
    ///
    /// It addresses the row by IDENTIFIER, never by its current name, and that is load-bearing rather than
    /// convenience. A seeded session's `displayName` starts as the cwd basename and is REPLACED the moment
    /// the shell emits its own OSC title, so a name captured a few lines earlier can already name nothing —
    /// resolving the element per use is what makes this immune. Matching a row by its VALUE is only safe for
    /// a name this test set itself.
    private func renameSeededSession(to newName: String) {
        let row = sessionRow()
        XCTAssertTrue(row.waitForHittable(timeout: 10), "the seeded session row should be hittable")
        let field = app.descendants(matching: .any).matching(identifier: "edit-field").firstMatch
        var editing = false
        for _ in 0..<5 {
            row.doubleClick()
            if field.waitForExistence(timeout: 2) { editing = true; break }
        }
        XCTAssertTrue(editing, "rename did not enter edit mode for the seeded row (field never appeared)")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("\(newName)\r")
        XCTAssertTrue(sessionRow(named: newName).waitForExistence(timeout: 5), "renamed session row should appear")
    }

    // MARK: - Element lookups

    /// The bottom-bar focus-filter toggle — both the indicator and the control.
    private func filterToggle() -> XCUIElement { app.buttons["focus-filter-toggle"] }

    /// Polls until the filter toggle reports `value` (`on`/`off`, its accessibility value) AND `enabled`.
    /// Both are needed to identify the state: the value says whether the filter applies, and the enabled
    /// flag is the only accessible read of whether ANYTHING is marked — off+disabled (nothing marked) and
    /// off+enabled (marked but suspended) look identical without it. Polled, not read once, because the
    /// sidebar mutation and the toggle's re-render settle asynchronously after a click or a menu item.
    private func pollFilterToggle(value: String, enabled: Bool, timeout: TimeInterval = 8) -> Bool {
        let toggle = filterToggle()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if toggle.exists, (toggle.value as? String) == value, toggle.isEnabled == enabled { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return toggle.exists && (toggle.value as? String) == value && toggle.isEnabled == enabled
    }

    /// The (first) session row, matched by its stable accessibility identifier.
    private func sessionRow() -> XCUIElement { app.staticTexts["session-row"] }

    /// A session row matched by its displayed name (lands in the StaticText `value`). Constrained to the
    /// `session-row` identifier so it never matches the window title (same cwd-basename text).
    private func sessionRow(named name: String) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "identifier == %@ AND value == %@", "session-row", name))
            .firstMatch
    }

    /// The on-screen (hittable) menu item with `title`, filtering out the closed menu-bar twin.
    private func presentedMenuItem(_ title: String, timeout: TimeInterval = 5) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let matches = app.menuItems.matching(identifier: title).allElementsBoundByIndex
            if let hit = matches.first(where: { $0.exists && $0.isHittable }) { return hit }
            usleep(150_000)
        }
        return app.menuItems[title].firstMatch
    }
}
