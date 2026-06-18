import XCTest

/// Drives the Settings window (Cmd+,): confirms the three tabs exist and that choosing a theme in
/// Appearance persists to the hermetic `settings.json` (file oracle, like the other UI tests).
@MainActor
final class SettingsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agt-uitest-\(UUID().uuidString)", isDirectory: true)
        app = XCUIApplication()
        app.launchEnvironment["AGT_STATE_DIR"] = stateDir.path
        app.launch()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    func testSettingsWindowHasThreeTabsAndThemePersists() throws {
        app.typeKey(",", modifierFlags: .command)

        // the three tabs are reachable.
        for tab in ["General", "Appearance", "Key Mapping"] {
            XCTAssertTrue(app.buttons[tab].firstMatch.waitForExistence(timeout: 5), "Settings should have a \(tab) tab")
        }

        app.buttons["Appearance"].firstMatch.click()

        // pick a known theme from the theme picker and confirm it lands in settings.json.
        let themePicker = app.descendants(matching: .any).matching(identifier: "settings-theme").firstMatch
        XCTAssertTrue(themePicker.waitForExistence(timeout: 5), "Appearance should have a theme picker")
        themePicker.click()
        let choice = app.menuItems["Alabaster"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "the theme menu should list themes")
        choice.click()

        XCTAssertTrue(poll { self.settingsValue("theme") == "Alabaster" }, "the chosen theme should persist to settings.json")
    }

    // MARK: - Helpers

    private func poll(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(150_000)
        }
        return false
    }

    private func settingsValue(_ key: String) -> String? {
        let file = stateDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj[key] as? String
    }
}
