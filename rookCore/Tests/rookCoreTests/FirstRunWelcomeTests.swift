import Foundation
import Testing
@testable import rookCore

struct FirstRunWelcomeTests {
    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("first-run-welcome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func isDueOnAFreshStateDirectory() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FirstRunWelcome.isDue(in: dir))
    }

    @Test func isDueWhenTheStateDirectoryDoesNotExistYet() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("first-run-welcome-absent-\(UUID().uuidString)", isDirectory: true)
        #expect(FirstRunWelcome.isDue(in: dir))
        #expect(!FirstRunWelcome.hasPriorState(in: dir))
    }

    @Test func isNotDueOnceShown() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        FirstRunWelcome.markShown(in: dir)
        #expect(!FirstRunWelcome.isDue(in: dir))
    }

    /// The launch that shows the welcome may be the one that creates the state directory, so the marker
    /// write cannot assume it exists.
    @Test func markingCreatesTheStateDirectory() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("first-run-welcome-new-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FirstRunWelcome.markShown(in: dir)
        #expect(!FirstRunWelcome.isDue(in: dir))
    }

    @Test(arguments: FirstRunWelcome.priorStateNames)
    func anySavedStateFileMeansAnUpgradingUserNeverSeesIt(name: String) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent(name))
        #expect(FirstRunWelcome.hasPriorState(in: dir))
        #expect(!FirstRunWelcome.isDue(in: dir))
    }

    @Test func aWindowsDirectoryCountsAsPriorState() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("windows", isDirectory: true),
                                                withIntermediateDirectories: true)
        #expect(FirstRunWelcome.hasPriorState(in: dir))
    }

    /// The socket is bound before the scene task reads prior state, so counting it would suppress the
    /// welcome on the very launch that owes it.
    @Test func theControlSocketIsNotPriorState() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("rook.sock"))
        #expect(!FirstRunWelcome.hasPriorState(in: dir))
        #expect(FirstRunWelcome.isDue(in: dir))
    }

    @Test func messageNamesEveryHelpMenuInstaller() {
        #expect(FirstRunWelcome.message.contains("agent skill"))
        #expect(FirstRunWelcome.message.contains("agent status hooks"))
        #expect(FirstRunWelcome.message.contains("command line tool"))
    }

    /// The CLI has no checkbox: a Homebrew install already links `rookctl`, so the alert only mentions it.
    @Test func onlyTheTwoInstallableExtrasAreOffered() {
        #expect(FirstRunWelcome.skillOption.contains("agent skill"))
        #expect(FirstRunWelcome.hooksOption.contains("agent status hooks"))
    }
}
