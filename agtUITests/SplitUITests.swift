import XCTest

/// End-to-end test for the one-level vertical split. The split panes are Metal
/// `GhosttySurfaceView`s with no readable accessibility text, so this uses the terminal
/// itself as the oracle: each pane's shell has a distinct `tty`, so typing `tty > file`
/// in the focused pane records which shell received the keystrokes. That verifies the
/// split opens a separate shell, that opening keeps focus on the current pane, that the
/// keyboard nav (⌘⌥←/→) moves focus between panes, and that closing keeps the focused pane.
@MainActor
final class SplitUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!
    private var markerDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agt-uitest-\(UUID().uuidString)", isDirectory: true)
        markerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agt-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["AGT_STATE_DIR"] = stateDir.path
        app.launchForUITest()
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
        if let markerDir { try? FileManager.default.removeItem(at: markerDir) }
    }

    func testSplitFocusKeyboardNavAndCollapse() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        // ensure the primary terminal holds focus before typing.
        row.click()
        usleep(800_000)

        // 1. record the primary shell's tty.
        let primaryTTY = ttyAfterCommand(named: "primary")
        XCTAssertNotNil(primaryTTY, "primary shell should write its tty (terminal must be focused)")

        // 2. open the split — focus STAYS on the current (primary) pane, it does not jump to the right.
        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")
        splitButton.click()
        usleep(800_000)
        let afterOpenTTY = ttyAfterCommand(named: "afteropen")
        XCTAssertEqual(afterOpenTTY, primaryTTY, "opening the split keeps focus on the current (primary) pane")

        // 3. Cmd+Opt+Right focuses the new right pane (a separate shell).
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        let rightTTY = ttyAfterCommand(named: "right")
        XCTAssertNotNil(rightTTY, "right shell should write its tty")
        XCTAssertNotEqual(rightTTY, primaryTTY, "Cmd+Opt+Right focuses the separate right shell")

        // 4. Cmd+Opt+Left focuses the primary pane again.
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        let leftTTY = ttyAfterCommand(named: "left")
        XCTAssertEqual(leftTTY, primaryTTY, "Cmd+Opt+Left focuses the primary shell")

        // 5. focus the right pane, then close the split — the focused (right) pane is kept maximized,
        // its shell alive, not the primary.
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        usleep(500_000)
        splitButton.click()
        usleep(800_000)
        let collapsedTTY = ttyAfterCommand(named: "collapsed")
        XCTAssertEqual(collapsedTTY, rightTTY, "closing the split keeps the focused (right) pane, not the primary")
    }

    /// Types `tty > <markerDir>/<name>` into the focused terminal and returns the tty the
    /// shell wrote (trimmed), or nil if nothing was written within the timeout.
    private func ttyAfterCommand(named name: String) -> String? {
        let file = markerDir.appendingPathComponent(name)
        app.typeText("tty > '\(file.path)'")
        app.typeKey(.return, modifierFlags: [])
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let contents = try? String(contentsOf: file, encoding: .utf8) {
                let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            usleep(150_000)
        }
        return nil
    }
}
