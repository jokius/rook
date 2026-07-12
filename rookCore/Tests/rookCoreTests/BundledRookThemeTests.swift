import Foundation
import Testing
@testable import rookCore

/// Guards the committed `rook/Resources/custom-themes/rook` theme — the file `SettingsStore.load()`
/// seeds on a fresh install (`AppSettings.defaultTheme`) and `scripts/setup.sh` stages into the
/// bundled `ghostty/themes` dir. It is plain data with no compiler behind it, so a typo (bad hex, a
/// missing key, a dropped palette slot) would only surface as a libghostty config diagnostic at
/// runtime. This parses the real file off disk and pins its shape plus the brand green.
struct BundledRookThemeTests {
    /// Repo root, walked up from this test source file (rookCore/Tests/rookCoreTests/…).
    private static let themeURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // rookCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // rookCore
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("rook/Resources/custom-themes/\(AppSettings.defaultTheme)")

    /// `key = value` pairs, with the `palette = N=#hex` entries keyed as `palette.N`.
    private static func entries() throws -> [String: String] {
        let text = try String(contentsOf: themeURL, encoding: .utf8)
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "palette" {
                let slot = parts[1].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                #expect(slot.count == 2, "malformed palette line: \(line)")
                result["palette.\(slot[0])"] = slot[1]
            } else {
                result[parts[0]] = parts[1]
            }
        }
        return result
    }

    private func isHex(_ value: String?) -> Bool {
        guard let value, value.count == 7, value.hasPrefix("#") else { return false }
        return value.dropFirst().allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    @Test func hasAllSixteenPaletteSlotsAndTheRequiredKeysAsLowercaseHex() throws {
        let entries = try Self.entries()
        for slot in 0...15 {
            #expect(isHex(entries["palette.\(slot)"]), "palette slot \(slot) missing or not a #rrggbb hex")
        }
        for key in ["background", "foreground", "cursor-color", "cursor-text", "selection-background", "selection-foreground"] {
            #expect(isHex(entries[key]), "\(key) missing or not a #rrggbb hex")
        }
    }

    @Test func carriesTheBrandGreenAndInkOnGraphite() throws {
        let entries = try Self.entries()
        let green = "#7ece8f", graphite = "#191c20"
        #expect(entries["palette.2"] == green)             // ANSI green = the brand accent
        #expect(entries["cursor-color"] == green)
        #expect(entries["selection-background"] == green)
        #expect(entries["background"] == graphite)
        #expect(entries["foreground"] == "#e6e1d7")        // brand ink
        // text drawn ON the green (cursor cell, selection) is the dark graphite, not the ink.
        #expect(entries["cursor-text"] == graphite)
        #expect(entries["selection-foreground"] == graphite)
    }

    @Test func backgroundClassifiesAsDark() throws {
        // ThemeBrightness.isDark is the runtime consumer of this background (it picks the sidebar's
        // selection colors), so the theme must land on the dark side of it.
        let background = try #require(try Self.entries()["background"])
        let bytes = background.dropFirst()
        let channel = { (offset: Int) -> Double in
            let start = bytes.index(bytes.startIndex, offsetBy: offset)
            let end = bytes.index(start, offsetBy: 2)
            return Double(UInt8(bytes[start..<end], radix: 16) ?? 0) / 255
        }
        #expect(ThemeBrightness.isDark(red: channel(0), green: channel(2), blue: channel(4)))
    }
}
