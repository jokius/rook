import XCTest

/// Drives the fork-only undo toast and the new close/undo settings toggles. The toast test closes the
/// seeded session (⌘W → a grace-period soft close, confirm defaults off) and asserts the themed toast
/// appears and its Reopen button restores the session; the settings tests assert the new toggles/stepper
/// persist to the hermetic `settings.json` (file oracle, like `SettingsUITests`).
@MainActor
final class UndoToastUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rook-uitest-\(UUID().uuidString)", isDirectory: true)
        app = XCUIApplication()
        app.launchEnvironment["ROOK_STATE_DIR"] = stateDir.path
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForHittable(timeout: 20), "seeded session should be hittable")
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    /// Close the seeded session with ⌘W (confirm off, undo grace on by default) → the toast appears; its
    /// Reopen button brings the session back before the grace expires.
    func testUndoToastAppearsAndReopenRestores() throws {
        let sessionRow = app.staticTexts["session-row"].firstMatch
        XCTAssertTrue(sessionRow.exists, "one seeded session at launch")

        app.typeKey("w", modifierFlags: .command) // Close Session → soft close + toast

        let toast = element(byID: "pending-close-toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 8), "the undo toast should appear after a grace-period close")
        XCTAssertTrue(poll { !app.staticTexts["session-row"].firstMatch.exists },
                      "the closed session's row should be gone during the grace window")

        let reopen = element(byID: "pending-close-reopen")
        XCTAssertTrue(reopen.waitForHittable(timeout: 5), "the toast should offer a Reopen button")
        reopen.click()

        XCTAssertTrue(poll { app.staticTexts["session-row"].firstMatch.exists },
                      "Reopen should restore the closed session")
    }

    /// The "Only when a session is running an agent" sub-option is disabled until the primary
    /// confirm-before-closing is on; enabling it then persists `confirmCloseOnlyRunningAgent=true`.
    func testConfirmCloseOnlyRunningAgentTogglePersists() throws {
        let primary = settingsControl(tab: "General", control: "settings-confirm-close-session")
        primary.click() // turn the primary toggle on (default off)
        XCTAssertTrue(poll { self.settingsBool("confirmCloseSession") == true },
                      "turning confirm-before-closing on should persist confirmCloseSession=true")

        let sub = settingsControl(tab: "General", control: "settings-confirm-close-running-agent")
        XCTAssertTrue(sub.isEnabled, "the sub-option should enable once the primary toggle is on")
        sub.click() // turn the sub-option on
        XCTAssertTrue(poll { self.settingsBool("confirmCloseOnlyRunningAgent") == true },
                      "turning the agent-only sub-option on should persist confirmCloseOnlyRunningAgent=true")
    }

    /// The Interface ▸ Undo "Show undo toast" toggle defaults on; turning it off persists `showUndoToast=false`.
    func testShowUndoToastTogglePersists() throws {
        let toggle = settingsControl(tab: "Interface", control: "settings-show-undo-toast")
        toggle.click() // turn it off (default on)
        XCTAssertTrue(poll { self.settingsBool("showUndoToast") == false },
                      "turning the undo toast off should persist showUndoToast=false")
    }

    /// The Interface ▸ Undo duration stepper defaults to 5s (nil); incrementing it persists a >5 value.
    func testUndoDurationStepperPersists() throws {
        let stepper = settingsControl(tab: "Interface", control: "settings-undo-duration")
        let increment = stepper.descendants(matching: .incrementArrow).firstMatch
        XCTAssertTrue(increment.waitForExistence(timeout: 5), "the undo-duration stepper should expose an increment arrow")
        increment.click() // 5 (default/nil) → 6

        XCTAssertTrue(poll { (self.settingsDouble("closeGraceSeconds") ?? 5) > 5 },
                      "incrementing the undo-duration stepper should persist a >5 closeGraceSeconds")
    }

    // MARK: - Helpers

    private func element(byID id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Opens the Settings window (Cmd+,) if needed, switches to `tab`, and returns the control with
    /// `control` id once it is hittable — RETRYING the tab click each tick (mirrors `SettingsUITests`,
    /// robust to a half-open/non-key Settings window dropping the first click).
    @discardableResult
    private func settingsControl(tab: String, control: String, timeout: TimeInterval = 12,
                                 file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = app.descendants(matching: .any).matching(identifier: control).firstMatch
        let tabButton = app.buttons[tab].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if target.exists, target.isHittable { return target }
            if tabButton.exists, tabButton.isHittable {
                tabButton.click()
            } else {
                app.typeKey(",", modifierFlags: .command) // settings not open yet (or lost) — (re)open
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("Settings '\(tab)' control '\(control)' never became hittable", file: file, line: line)
        return target
    }

    private func poll(_ condition: () -> Bool, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(150_000)
        }
        return false
    }

    private func settingsBool(_ key: String) -> Bool? {
        (settingsObject()?[key] as? NSNumber)?.boolValue
    }

    private func settingsDouble(_ key: String) -> Double? {
        (settingsObject()?[key] as? NSNumber)?.doubleValue
    }

    private func settingsObject() -> [String: Any]? {
        let file = stateDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
