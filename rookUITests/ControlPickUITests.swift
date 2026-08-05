import XCTest

/// End-to-end coverage for the native control picker (`pick.open`/`pick.result`/`pick.cancel`). The
/// socket drives real per-window `PickController` state while XCUITest verifies the SwiftUI picker: the
/// palette reused for a caller-supplied list answers to `pick-palette`/`pick-scrim` rather than the
/// built-in feeds' `command-palette`/`palette-scrim`, and its rows to `palette-item-<caller id>` — the
/// ids are the test's own strings, so a picker is driven without capturing a UUID off the wire.
///
/// The lifecycle cases are the ones a unit test cannot reach: ⌘W and a real AppKit window close must
/// RESOLVE a pending pick, because a socket caller is blocked on the answer and hiding the picker would
/// leave it waiting forever.
@MainActor
final class ControlPickUITests: ControlAPITestCase {
    // the whole happy path in one launch: the picker mounts with the caller's rows, `tree` reports the
    // pending id, and clicking a row answers the poll with that row's identity.
    func testPickPresentsRowsReportsPendingAndReturnsTheChosenRow() throws {
        let pickID = try openedPickID([
            ["id": "alpha", "label": "Alpha", "subtitle": "first choice"],
            ["id": "beta", "label": "Beta", "subtitle": "second choice"],
        ], prompt: "Choose a target")

        XCTAssertTrue(pickPalette.waitForExistence(timeout: 15), "pick.open should present the native picker")
        XCTAssertTrue(paletteRow("alpha").waitForExistence(timeout: 10), "the caller's Alpha row should appear")
        XCTAssertTrue(paletteRow("beta").waitForExistence(timeout: 10), "the caller's Beta row should appear")
        XCTAssertTrue(app.staticTexts["Alpha"].exists, "the first supplied label should be visible")
        XCTAssertEqual(try treePickPending(), pickID, "tree should expose the live picker id in pickPending")

        clickPaletteRow("beta")

        let result = try awaitTerminalResult(id: pickID)
        XCTAssertEqual(result["result"] as? String, "picked")
        XCTAssertEqual(result["id"] as? String, "beta", "the caller gets back the id it supplied for that row")
        XCTAssertEqual(result["label"] as? String, "Beta")
        XCTAssertEqual(result["index"] as? Int, 1, "the reported index is the caller's array position")
        XCTAssertTrue(pickPalette.waitForNonExistence(timeout: 10), "choosing a row should dismiss the picker")
        XCTAssertNil(try treePickPending(), "tree should omit pickPending once the picker resolved")
    }

    // an EMPTY item list is legal with --allow-custom: the picker becomes a text prompt, and --query
    // opens it already carrying the value, so Return alone commits an answer.
    func testItemlessPickerWithQueryAndAllowCustomReturnsTheQuery() throws {
        let pickID = try openedPickID([], query: "old name", allowCustom: true)

        XCTAssertTrue(pickPalette.waitForExistence(timeout: 15),
                      "an empty item list with allowCustom should still present the picker")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the picker query field should exist")
        XCTAssertEqual(field.value as? String, "old name", "the field should open carrying the caller's query")
        XCTAssertTrue(paletteRow("pick-custom").waitForExistence(timeout: 10),
                      "with no item to match, the seeded query should offer the free-text row")
        XCTAssertTrue(app.staticTexts["Use \"old name\""].exists, "the custom row should show the value it commits")

        app.typeKey(.return, modifierFlags: [])

        let result = try awaitTerminalResult(id: pickID)
        XCTAssertEqual(result["result"] as? String, "custom", "an itemless picker can only resolve as custom")
        XCTAssertEqual(result["query"] as? String, "old name")
        XCTAssertTrue(pickPalette.waitForNonExistence(timeout: 10), "committing should dismiss the picker")
    }

    // one picker per window, and `pick.cancel` resolves the pending one rather than leaving the caller
    // polling. Both share a launch: the rejection needs a live picker anyway.
    func testSecondPickIsRejectedAndPickCancelResolvesTheFirst() throws {
        let pickID = try openedPickID([["id": "one", "label": "One"]])
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 15), "the first picker should be visible")

        let second = try sendCommand(request(command: "pick.open", args: ["items": [["id": "two", "label": "Two"]]]))
        XCTAssertEqual(second["ok"] as? Bool, false, "a window hosts only one pending picker: \(second)")
        XCTAssertEqual(second["error"] as? String, "pick already pending")

        let cancelled = try sendCommand(request(command: "pick.cancel", target: pickID))
        XCTAssertEqual(cancelled["ok"] as? Bool, true, "pick.cancel should succeed: \(cancelled)")
        XCTAssertEqual(try awaitTerminalResult(id: pickID)["result"] as? String, "cancelled")
        XCTAssertTrue(pickPalette.waitForNonExistence(timeout: 10), "cancellation should dismiss the picker")
        XCTAssertNil(try treePickPending(), "tree should omit pickPending after cancellation")
    }

    // ⌘W is the FIRST rung of the close ladder: it resolves the pick so the blocked caller finishes, and
    // must not fall through to closing the session behind the picker.
    func testCommandWResolvesThePendingPickInsteadOfClosingTheSession() throws {
        let sessionID = try activeSessionID()
        let pickID = try openedPickID([["id": "one", "label": "One"]])
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 15), "pick.open should present the picker")

        app.typeKey("w", modifierFlags: .command)

        XCTAssertEqual(try awaitTerminalResult(id: pickID)["result"] as? String, "cancelled",
                       "⌘W must resolve the pick, not merely hide it")
        XCTAssertTrue(pickPalette.waitForNonExistence(timeout: 10), "⌘W should dismiss the picker")
        XCTAssertEqual(try activeSessionID(), sessionID,
                       "⌘W consumed by the picker must leave the session behind it open")
    }

    // a poll that lands AFTER the picker's window is gone still reads its own answer: the registry
    // cancels on the real AppKit close edge and retains the result by pick id.
    func testClosingTheWindowResolvesThePickForALatePoll() throws {
        let created = try sendCommand(#"{"cmd":"window.new","args":{"name":"pick-owner"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "window.new should succeed: \(created)")
        let windowID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String,
                                    "window.new should return the new window id")

        let pickID = try openedPickID([["id": "one", "label": "One"]], window: windowID)
        XCTAssertEqual(try treePickPending(window: windowID), pickID,
                       "--window should put the picker in the named window")

        let closed = try sendCommand(#"{"cmd":"window.close","target":"\#(windowID)"}"#)
        XCTAssertEqual(closed["ok"] as? Bool, true, "window.close should succeed: \(closed)")

        // no window selector: the pick id is globally unique, which is what lets the poll outlive the
        // window it was opened in.
        XCTAssertEqual(try awaitTerminalResult(id: pickID)["result"] as? String, "cancelled",
                       "closing the window must resolve its pending pick rather than strand the caller")
    }

    // MARK: - Picker helpers

    private var pickPalette: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "pick-palette").firstMatch
    }

    private func paletteRow(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "palette-item-\(id)").firstMatch
    }

    /// A row WITH a subtitle answers to its identifier twice — the title child carries it too and is never
    /// hittable, because the row owns the tap target — so click the first HITTABLE match. Resolving the
    /// matches is eager, which is why this is separate from `paletteRow`: doing it inside an existence wait
    /// (which runs before the row exists) would break the wait.
    private func clickPaletteRow(_ id: String) {
        let matches = app.descendants(matching: .any).matching(identifier: "palette-item-\(id)")
        (matches.allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch).click()
    }

    /// Opens a picker and returns its id — `pick.open` answers with the PICKER's id, never the choice.
    private func openedPickID(_ items: [[String: Any]], prompt: String? = nil, query: String? = nil,
                              allowCustom: Bool = false, window: String? = nil) throws -> String {
        var args: [String: Any] = ["items": items]
        if let prompt { args["prompt"] = prompt }
        if let query { args["query"] = query }
        if allowCustom { args["allowCustom"] = true }
        if let window { args["window"] = window }
        let response = try sendCommand(request(command: "pick.open", args: args))
        XCTAssertEqual(response["ok"] as? Bool, true, "pick.open should succeed: \(response)")
        return try XCTUnwrap((response["result"] as? [String: Any])?["id"] as? String,
                             "pick.open should return the new picker id")
    }

    /// Polls `pick.result` until the nested payload leaves `pending`, then returns it. A human answers in
    /// seconds, so every terminal-state assertion goes through this rather than a single read.
    private func awaitTerminalResult(id: String, timeout: TimeInterval = 15) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: [String: Any]?
        repeat {
            let response = try sendCommand(request(command: "pick.result", target: id))
            XCTAssertEqual(response["ok"] as? Bool, true, "pick.result should succeed: \(response)")
            latest = (response["result"] as? [String: Any])?["pick"] as? [String: Any]
            if latest?["result"] as? String != "pending" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        let result = try XCTUnwrap(latest, "pick.result should carry a nested pick payload")
        XCTAssertNotEqual(result["result"] as? String, "pending", "the picker should resolve before the timeout")
        return result
    }

    // MARK: - Tree helper

    private func treePickPending(window: String? = nil) throws -> String? {
        var args: [String: Any]?
        if let window { args = ["window": window] }
        let response = try sendCommand(request(command: "tree", args: args))
        XCTAssertEqual(response["ok"] as? Bool, true, "tree should succeed: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "tree should carry a result")
        let tree = try XCTUnwrap(result["tree"] as? [String: Any], "the tree result should carry a tree")
        return tree["pickPending"] as? String
    }

    /// `items` carries arrays of dictionaries, so the request line is serialized rather than interpolated.
    private func request(command: String, target: String? = nil, args: [String: Any]? = nil) -> String {
        var object: [String: Any] = ["cmd": command]
        if let target { object["target"] = target }
        if let args { object["args"] = args }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}
