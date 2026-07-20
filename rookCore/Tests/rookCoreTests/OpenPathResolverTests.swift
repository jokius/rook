import Foundation
import Testing
@testable import rookCore

struct OpenPathResolverTests {
    @Test func folderResolvesToItself() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rook-openpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(OpenPathResolver.directory(for: dir) == dir.path)
    }

    @Test func regularFileResolvesToItsParent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rook-openpath-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(OpenPathResolver.directory(for: file) == file.deletingLastPathComponent().path)
    }

    @Test func missingPathResolvesToNil() {
        let missing = URL(fileURLWithPath: "/no/such/rook/path/\(UUID().uuidString)")
        #expect(OpenPathResolver.directory(for: missing) == nil)
    }

    @Test func nonFileURLResolvesToNil() throws {
        let web = try #require(URL(string: "https://rook.app"))
        #expect(OpenPathResolver.directory(for: web) == nil)
    }
}
