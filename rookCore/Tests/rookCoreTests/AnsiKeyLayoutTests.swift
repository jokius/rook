import Foundation
import Testing
@testable import rookCore

/// The layout half of `NSEvent` → `Chord`. Every `produced:` fixture below is a MEASURED value: the
/// layouts installed on macOS 26 translated through `UCKeyTranslate` (the same call AppKit makes to fill
/// `NSEvent.characters`), not a guess at what a keyboard prints. The app-side monitors can only ever
/// exercise the branch matching the tester's own live input source, so the policy itself lives here where
/// `layoutIsASCIICapable` is a parameter.
struct AnsiKeyLayoutTests {
    @Test func latinKeyCoversEveryAnsiLetterAndDigit() {
        let produced = (0...127).compactMap { latinKey(forKeyCode: UInt16($0)) }
        #expect(produced.count == Set(produced).count, "a physical position must map to one Latin key")
        let letters = Set("abcdefghijklmnopqrstuvwxyz".map(String.init))
        let digits = Set("0123456789".map(String.init))
        #expect(letters.isSubset(of: Set(produced)))
        #expect(digits.isSubset(of: Set(produced)))
        #expect(Set(produced).subtracting(letters).subtracting(digits) == ["=", "-", "]", "[", "'", ";", "\\", ",", "/", ".", "`"])
    }

    @Test func latinKeyValuesAreAllSpellableAsChords() {
        // a fallback the grammar can't spell would fire nothing — the same parses-but-never-fires failure
        // mode `bindableNamedKeys` guards from the other direction.
        for key in (0...127).compactMap({ latinKey(forKeyCode: UInt16($0)) }) {
            #expect(parseKeybind("cmd+\(key)") == [Chord(mods: .command, key: key)], "cmd+\(key) must parse")
        }
    }

    @Test func latinKeyAndNamedKeyNeverClaimTheSameKeyCode() {
        // both monitors resolve the named key FIRST, so an overlap would silently shadow one of the maps.
        for code in 0...127 where namedKey(forKeyCode: UInt16(code)) != nil {
            #expect(latinKey(forKeyCode: UInt16(code)) == nil, "keyCode \(code) is claimed twice")
        }
    }

    /// Every entry pinned one by one. The aggregate tests above hold under any permutation of the 47
    /// entries, and the real `kVK_ANSI_*` constants are non-monotonic at 4/5 (h/g), 22/23 (6/5) and
    /// 25/26/28/29 (9/7/8/0) — where a transposition is easiest to make and hardest to eyeball. A swap
    /// would bind a chord to the wrong physical key on every non-Latin layout.
    @Test func latinKeyMapsEachKeyCodeToItsOwnAnsiCharacter() {
        let table: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
            11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
            24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
            31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
        ]
        for (code, expected) in table {
            #expect(latinKey(forKeyCode: code) == expected, "keyCode \(code) must be '\(expected)'")
        }
        let mapped = Set((0...127).compactMap { latinKey(forKeyCode: UInt16($0)) != nil ? UInt16($0) : nil })
        #expect(mapped == Set(table.keys), "the table and the function must claim the same key codes")
    }

    @Test func chordKeyKeepsTheProducedCharacterOnAnASCIICapableLayout() {
        #expect(chordKey(forKeyCode: 31, produced: "o", layoutIsASCIICapable: true) == "o")
        #expect(chordKey(forKeyCode: 8, produced: "j", layoutIsASCIICapable: true) == "j",
                "Dvorak keeps its own letter positions")
        #expect(chordKey(forKeyCode: 44, produced: "/", layoutIsASCIICapable: true) == "/")
        #expect(chordKey(forKeyCode: 0, produced: "A", layoutIsASCIICapable: true) == "a",
                "the base key is always lowercased")
        #expect(chordKey(forKeyCode: 19, produced: "é", layoutIsASCIICapable: true) == "é",
                "French is ASCII-capable, so it binds what it types and cmd+é still fires")
    }

    @Test func chordKeyResolvesAnyNonASCIILayoutByPhysicalPosition() {
        #expect(chordKey(forKeyCode: 31, produced: "щ", layoutIsASCIICapable: false) == "o", "Russian O")
        #expect(chordKey(forKeyCode: 17, produced: "е", layoutIsASCIICapable: false) == "t", "Russian T")
        #expect(chordKey(forKeyCode: 6, produced: "я", layoutIsASCIICapable: false) == "z", "Russian Z, the ⌘Z of undo_close")
        // the positions a per-key ASCII test gets wrong: Greek types `;` at Q and Hebrew types `/` there,
        // so a letter chord would stay dead on the layouts this exists to serve.
        #expect(chordKey(forKeyCode: 12, produced: ";", layoutIsASCIICapable: false) == "q", "Greek Q")
        #expect(chordKey(forKeyCode: 12, produced: "/", layoutIsASCIICapable: false) == "q", "Hebrew Q")
        #expect(chordKey(forKeyCode: 13, produced: "'", layoutIsASCIICapable: false) == "w", "Hebrew-PC W")
        // and the punctuation RussianWin/Ukrainian-PC re-home: the `/` position types `.`, which used to be kept.
        #expect(chordKey(forKeyCode: 44, produced: ".", layoutIsASCIICapable: false) == "/")
    }

    /// Two physical keys must never resolve to one chord key: the second would fire a binding aimed at the
    /// first AND be swallowed by the monitor. Fixtures are the produced characters measured with
    /// `UCKeyTranslate` against the real layout data.
    @Test func chordKeyNeverCollapsesTwoPositionsOntoOneKeyOnANonASCIILayout() {
        let hebrew: [UInt16: String] = [39: ",", 43: "ת", 44: ".", 47: "ץ"]
        let greek: [UInt16: String] = [12: ";", 41: "΄"]
        let russianWin: [UInt16: String] = [44: ".", 47: "ю"]
        let ukrainianPC: [UInt16: String] = [42: "ʼ", 44: ".", 47: "ю"]
        for layout in [hebrew, greek, russianWin, ukrainianPC] {
            let keys = layout.map { chordKey(forKeyCode: $0.key, produced: $0.value, layoutIsASCIICapable: false) }
            #expect(keys.allSatisfy { $0 != nil })
            #expect(Set(keys.compactMap { $0 }).count == layout.count, "positions collapsed: \(keys)")
        }
    }

    /// The ISO key types a layout-dependent character from a position the table does not claim, so keeping
    /// it would alias the table position that types the same thing — one binding fired from two keys.
    @Test func chordKeyDropsTheISOSectionKeyOnANonASCIILayout() {
        #expect(chordKey(forKeyCode: 10, produced: "\\", layoutIsASCIICapable: false) == nil,
                "Ukrainian-PC types a backslash here, which keyCode 42 already owns")
        #expect(chordKey(forKeyCode: 10, produced: ";", layoutIsASCIICapable: false) == nil,
                "Hebrew-PC types a semicolon here, which keyCode 41 already owns")
        #expect(chordKey(forKeyCode: 10, produced: "§", layoutIsASCIICapable: true) == "§",
                "on a Latin layout it binds what it types, exactly as before")
    }

    @Test func chordKeyResolvesAPositionThatProducedNothing() {
        #expect(chordKey(forKeyCode: 31, produced: nil, layoutIsASCIICapable: false) == "o")
        #expect(chordKey(forKeyCode: 41, produced: "", layoutIsASCIICapable: false) == ";",
                "a dead key at a table position resolves to its Latin key, not to nil")
        // the ASCII-capable branch never consults the table, so a table position that produced nothing is
        // nil there — a composing dead key reports "" while it waits for the next press.
        #expect(chordKey(forKeyCode: 39, produced: "", layoutIsASCIICapable: true) == nil)
        #expect(chordKey(forKeyCode: 31, produced: nil, layoutIsASCIICapable: true) == nil)
    }

    @Test func chordKeyReturnsNilWithoutAUsableBaseKey() {
        #expect(chordKey(forKeyCode: 63, produced: nil, layoutIsASCIICapable: false) == nil,
                "the fn key carries no Latin key")
        #expect(chordKey(forKeyCode: 63, produced: nil, layoutIsASCIICapable: true) == nil)
        #expect(chordKey(forKeyCode: 49, produced: " ", layoutIsASCIICapable: true) == nil,
                "space is a named key, never a produced base key")
    }

    /// The end of the reported bug: a Latin-spelled `cmd+o` from `keymap.conf` must equal the chord the
    /// runner builds from the physical O key on the Russian layout that types `щ` there.
    @Test func cyrillicKeyPressMatchesTheLatinSpelledKeymapChord() throws {
        let key = try #require(chordKey(forKeyCode: 31, produced: "щ", layoutIsASCIICapable: false))
        #expect(parseKeybind("cmd+o") == [Chord(mods: .command, key: key)])
    }
}
