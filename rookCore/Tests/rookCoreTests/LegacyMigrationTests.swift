import Foundation
import Testing
@testable import rookCore

/// Class suite so `init`/`deinit` create and tear down a unique temp "home" per test — the migration is
/// pure FileManager work, so it is driven against a fake home + Application Support, never the real ones.
final class LegacyMigrationTests {
    private let root: URL
    private let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("rook-migration-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var appSupport: URL { root.appendingPathComponent("appsupport", isDirectory: true) }
    private var legacyState: URL { appSupport.appendingPathComponent("agterm", isDirectory: true) }
    private var newState: URL { appSupport.appendingPathComponent("rook", isDirectory: true) }
    private var legacyConfig: URL { home.appendingPathComponent(".config/agterm", isDirectory: true) }
    private var newConfig: URL { home.appendingPathComponent(".config/rook", isDirectory: true) }

    private func write(_ contents: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private func run(stateDir: String? = nil) -> LegacyMigration.Result {
        LegacyMigration.run(home: home, appSupport: appSupport, stateDir: stateDir)
    }

    /// A realistic legacy install: state (index + per-window snapshot + settings + a live socket) and config.
    private func seedLegacy() throws {
        try write("{\"version\":1}", to: legacyState.appendingPathComponent("windows.json"))
        try write("{\"w\":1}", to: legacyState.appendingPathComponent("windows/abc.json"))
        try write("{\"theme\":\"Brogrammer\"}", to: legacyState.appendingPathComponent("settings.json"))
        try write("socket", to: legacyState.appendingPathComponent("agterm.sock"))
        try write("map cmd+shift+d toggle_split", to: legacyConfig.appendingPathComponent("keymap.conf"))
        try write("font-size = 14", to: legacyConfig.appendingPathComponent("ghostty.conf"))
        try write("#!/bin/sh", to: legacyConfig.appendingPathComponent("agent-status/agterm-agent-status.sh"))
    }

    @Test func copiesStateAndConfigWhenOnlyLegacyExists() throws {
        try seedLegacy()

        let result = run()

        #expect(result.state == ["settings.json", "windows", "windows.json"])
        #expect(result.config == ["ghostty.conf", "keymap.conf"])
        #expect(read(newState.appendingPathComponent("windows/abc.json")) == "{\"w\":1}")
        #expect(read(newConfig.appendingPathComponent("keymap.conf")) == "map cmd+shift+d toggle_split")
    }

    @Test func skipsTheSocketAndTheAgentStatusHooks() throws {
        try seedLegacy()

        _ = run()

        #expect(!fm.fileExists(atPath: newState.appendingPathComponent("agterm.sock").path))
        #expect(!fm.fileExists(atPath: newConfig.appendingPathComponent("agent-status").path))
    }

    @Test func leavesTheLegacyDirectoriesInPlaceAsABackup() throws {
        try seedLegacy()

        _ = run()

        #expect(fm.fileExists(atPath: legacyState.appendingPathComponent("windows.json").path))
        #expect(fm.fileExists(atPath: legacyConfig.appendingPathComponent("keymap.conf").path))
    }

    @Test func isIdempotentAndNeverOverwritesAnExistingRookDirectory() throws {
        try seedLegacy()
        try write("{\"version\":2}", to: newState.appendingPathComponent("windows.json"))
        try write("map cmd+j toggle_scratch", to: newConfig.appendingPathComponent("keymap.conf"))

        let result = run()

        #expect(result.isEmpty)
        #expect(read(newState.appendingPathComponent("windows.json")) == "{\"version\":2}")
        #expect(read(newConfig.appendingPathComponent("keymap.conf")) == "map cmd+j toggle_scratch")
        // a second pass over the already-migrated install is a no-op too.
        try fm.removeItem(at: newState)
        #expect(!run().state.isEmpty)
        #expect(run().isEmpty)
    }

    @Test func doesNothingWhenNoLegacyInstallExists() {
        #expect(run().isEmpty)
        #expect(!fm.fileExists(atPath: newState.path))
        #expect(!fm.fileExists(atPath: newConfig.path))
    }

    /// A legacy config dir holding ONLY the (skipped) hooks must not leave an empty `~/.config/rook` behind —
    /// the destination is created only when something survives the skip filter.
    @Test func doesNotCreateADestinationWhenEverythingIsSkipped() throws {
        try write("#!/bin/sh", to: legacyConfig.appendingPathComponent("agent-status/rook-agent-status.sh"))

        #expect(run().config.isEmpty)
        #expect(!fm.fileExists(atPath: newConfig.path))
    }

    /// An isolated dev/test instance (ROOK_STATE_DIR set) must never inherit the real install's state.
    @Test func skipsMigrationEntirelyUnderAnIsolatedStateDir() throws {
        try seedLegacy()

        #expect(run(stateDir: "/tmp/rook-dev").isEmpty)
        #expect(!fm.fileExists(atPath: newState.path))
        #expect(!fm.fileExists(atPath: newConfig.path))
    }

    /// An empty ROOK_STATE_DIR is "unset" (the ConfigPaths convention), so migration still runs.
    @Test func treatsAnEmptyStateDirAsUnset() throws {
        try seedLegacy()

        #expect(!run(stateDir: "").isEmpty)
    }
}
