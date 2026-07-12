import Foundation
import Testing
@testable import rookCore

struct ThemeCatalogTests {
    @Test func namesInDirectorySortCaseInsensitively() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rook-themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in ["Nord", "alabaster", "Zenburn"] {
            try "".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        #expect(ThemeCatalog.names(in: dir.path) == ["alabaster", "Nord", "Zenburn"])
        #expect(ThemeCatalog.names(in: "/no/such/dir") == [])
    }

    @Test func entriesPutGhosttyDefaultBeforeNamedThemes() {
        let catalog = ThemeCatalog(names: ["Nord", "rook", "Adwaita Dark"])

        #expect(catalog.names == ["Adwaita Dark", "Nord", "rook"])
        #expect(catalog.entries == [
            ThemeCatalog.Entry(id: "theme:__default__", name: nil, title: "default ghostty"),
            ThemeCatalog.Entry(id: "theme:Adwaita Dark", name: "Adwaita Dark", title: "Adwaita Dark"),
            ThemeCatalog.Entry(id: "theme:Nord", name: "Nord", title: "Nord"),
            ThemeCatalog.Entry(id: "theme:rook", name: "rook", title: "rook"),
        ])
        #expect(catalog.entries.first?.isDefault == true)
    }

    @Test func idsRepresentDefaultAndNamedThemes() {
        #expect(ThemeCatalog.id(for: nil) == "theme:__default__")
        #expect(ThemeCatalog.id(for: "rook") == "theme:rook")
    }

    @Test func resolvedNameTreatsNilAndBlankAsDefault() {
        #expect(ThemeCatalog.resolvedName(nil) == nil)
        #expect(ThemeCatalog.resolvedName("") == nil)
        #expect(ThemeCatalog.resolvedName("   ") == nil)
        #expect(ThemeCatalog.resolvedName("  Nord  ") == "Nord")
    }

    @Test func containsMatchesBundledNamesExactly() {
        let catalog = ThemeCatalog(names: ["rook", "Nord"])

        #expect(catalog.contains(name: "rook"))
        #expect(catalog.contains(name: "Nord"))
        #expect(!catalog.contains(name: "nord"))
    }
}
