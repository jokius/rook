import Foundation
import Testing
@testable import rookCore

/// The host-free half of the workspace icon: the spec's tint rule, the raw-argument classifier, and the
/// state-dir storage (which is what makes an icon survive the user moving the original file).
struct WorkspaceIconTests {
    @Test func tintAppliesOnlyToMonochromeVectors() {
        // a symbol and an SVG load as TEMPLATE images, so the workspace color recolors them...
        #expect(WorkspaceIcon(kind: .symbol, value: "hammer.fill").isTintable)
        #expect(WorkspaceIcon(kind: .image, value: "/icons/rocket.svg").isTintable)
        #expect(WorkspaceIcon(kind: .image, value: "/icons/ROCKET.SVG").isTintable) // extension check is case-insensitive
        // ...while a raster and a color emoji carry their own colors: tinting would paint over the picture.
        #expect(!WorkspaceIcon(kind: .image, value: "/icons/logo.png").isTintable)
        #expect(!WorkspaceIcon(kind: .image, value: "/icons/photo.jpeg").isTintable)
        #expect(!WorkspaceIcon(kind: .emoji, value: "🚀").isTintable)
    }

    @Test func classifierSeparatesPathsEmojiAndSymbols() {
        // a path: it either has a separator or an image extension
        #expect(WorkspaceIcon.kind(forRawIcon: "/Users/me/icons/rocket.svg") == .image)
        #expect(WorkspaceIcon.kind(forRawIcon: "rocket.png") == .image) // no slash, but an image extension
        // a single emoji grapheme (including a multi-scalar one)
        #expect(WorkspaceIcon.kind(forRawIcon: "🚀") == .emoji)
        #expect(WorkspaceIcon.kind(forRawIcon: "👩‍💻") == .emoji) // ZWJ sequence is still ONE grapheme
        // anything else is an SF Symbol name — dot-separated ASCII, so it can't collide with the above
        #expect(WorkspaceIcon.kind(forRawIcon: "hammer.fill") == .symbol)
        #expect(WorkspaceIcon.kind(forRawIcon: "leaf") == .symbol)
    }

    @Test func emojiValidatorRejectsWordsDigitsAndRuns() {
        #expect(WorkspaceIcon.isValidEmoji("🚀"))
        #expect(!WorkspaceIcon.isValidEmoji("🚀🚀")) // two graphemes
        #expect(!WorkspaceIcon.isValidEmoji("rocket")) // a word must fall through to the symbol branch
        #expect(!WorkspaceIcon.isValidEmoji("7")) // digits are technically isEmoji but render as text
        #expect(!WorkspaceIcon.isValidEmoji(""))
    }

    @Test func codableRoundTrips() throws {
        let icon = WorkspaceIcon(kind: .image, value: "/state/workspace-icons/abc-1234abcd.svg")
        let decoded = try JSONDecoder().decode(WorkspaceIcon.self, from: JSONEncoder().encode(icon))
        #expect(decoded == icon)
    }

    // MARK: - storage

    @Test func installCopiesIntoTheStateDirWithAFreshName() throws {
        let (stateDir, source) = try makeIconFixture(ext: "svg")
        let workspaceID = UUID()

        let icon = try WorkspaceIconStorage.install(source: source, workspaceID: workspaceID, stateDir: stateDir)
        #expect(icon.kind == .image)
        #expect(FileManager.default.fileExists(atPath: icon.value), "the copy should exist in the icons dir")
        #expect(icon.value != source.path, "the icon must point at the COPY, not the user's file")
        #expect(URL(fileURLWithPath: icon.value).deletingLastPathComponent()
            == WorkspaceIconStorage.directoryURL(stateDir: stateDir), "the copy lives in the icons dir")
        #expect(FileManager.default.fileExists(atPath: source.path), "the user's original is left alone")

        // the icon survives the ORIGINAL being deleted — the whole point of copying it in.
        try FileManager.default.removeItem(at: source)
        #expect(FileManager.default.fileExists(atPath: icon.value))
    }

    /// The `tree` read-back hands a script the COPY's path, and feeding that back to `workspace.icon` is the
    /// documented record-then-restore. Source == destination must therefore be a no-op, not a
    /// remove-then-copy that deletes the only copy.
    @Test func installIsIdempotentWhenHandedItsOwnOutput() throws {
        let (stateDir, source) = try makeIconFixture(ext: "png")
        let workspaceID = UUID()

        let first = try WorkspaceIconStorage.install(source: source, workspaceID: workspaceID, stateDir: stateDir)
        let again = try WorkspaceIconStorage.install(source: URL(fileURLWithPath: first.value),
                                                     workspaceID: workspaceID, stateDir: stateDir)
        #expect(again == first, "re-installing the icon's own path must return it unchanged")
        #expect(FileManager.default.fileExists(atPath: first.value), "and must not delete the only copy")
        let files = try FileManager.default.contentsOfDirectory(atPath: WorkspaceIconStorage.directoryURL(stateDir: stateDir).path)
        #expect(files.count == 1, "no second copy should be made; got \(files)")
    }

    /// A destination named from the workspace id ALONE would make a swapped file produce an identical spec,
    /// which the store's delta guard, the sidebar's RowContent diff, and the image memo would each swallow.
    @Test func installGivesADifferentNameToASecondIcon() throws {
        let (stateDir, first) = try makeIconFixture(ext: "svg")
        let second = first.deletingLastPathComponent().appendingPathComponent("other.svg")
        try Data("<svg/>".utf8).write(to: second)
        let workspaceID = UUID()

        let a = try WorkspaceIconStorage.install(source: first, workspaceID: workspaceID, stateDir: stateDir)
        let b = try WorkspaceIconStorage.install(source: second, workspaceID: workspaceID, stateDir: stateDir)
        #expect(a != b, "a replacement icon must be a DIFFERENT spec, or nothing downstream re-renders")
    }

    /// A temp state dir plus a source image file outside it.
    private func makeIconFixture(ext: String) throws -> (stateDir: URL, source: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rook-icons-\(UUID().uuidString)")
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let sourceDir = root.appendingPathComponent("pictures", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let source = sourceDir.appendingPathComponent("icon.\(ext)")
        try Data("<svg/>".utf8).write(to: source)
        return (stateDir, source)
    }
}
