import Foundation

/// The Latin base character at a physical ANSI key position, or `nil` for a position that carries no
/// Latin key (a named key, a function key, the keypad). The letters, digits, and punctuation of the ANSI
/// layout keyed by macOS virtual key code — every value is a single character `parseKeybind` accepts as
/// a base key, so each one is spellable in `keymap.conf`.
///
/// This is the layout-INDEPENDENT half of key resolution: a virtual key code names a physical position
/// and never changes with the active input source, unlike the character that position produces.
func latinKey(forKeyCode keyCode: UInt16) -> String? {
    switch keyCode {
    case 0: return "a"
    case 1: return "s"
    case 2: return "d"
    case 3: return "f"
    case 4: return "h"
    case 5: return "g"
    case 6: return "z"
    case 7: return "x"
    case 8: return "c"
    case 9: return "v"
    case 11: return "b"
    case 12: return "q"
    case 13: return "w"
    case 14: return "e"
    case 15: return "r"
    case 16: return "y"
    case 17: return "t"
    case 18: return "1"
    case 19: return "2"
    case 20: return "3"
    case 21: return "4"
    case 22: return "6"
    case 23: return "5"
    case 24: return "="
    case 25: return "9"
    case 26: return "7"
    case 27: return "-"
    case 28: return "8"
    case 29: return "0"
    case 30: return "]"
    case 31: return "o"
    case 32: return "u"
    case 33: return "["
    case 34: return "i"
    case 35: return "p"
    case 37: return "l"
    case 38: return "j"
    case 39: return "'"
    case 40: return "k"
    case 41: return ";"
    case 42: return "\\"
    case 43: return ","
    case 44: return "/"
    case 45: return "n"
    case 46: return "m"
    case 47: return "."
    case 50: return "`"
    default: return nil
    }
}

/// The ISO-only key left of Z (macOS `kVK_ISO_Section`), absent from an ANSI keyboard and from `latinKey`.
private let isoSectionKeyCode: UInt16 = 10

/// The base key for one key press. `produced` is the character the ACTIVE layout puts on that position
/// with no modifiers applied (the app-side monitors pass what the `NSEvent` reports), and
/// `layoutIsASCIICapable` says whether that layout can type ASCII at all.
///
/// The choice is per LAYOUT, not per key. An ASCII-capable layout — US, Dvorak, Colemak,
/// US-International, French, German — binds the character it produces, so a chord follows the letter on
/// the key cap and an alternative Latin layout keeps its own letter positions; nothing an existing user
/// has bound changes. A layout that cannot type ASCII — Russian, Ukrainian, Greek, Hebrew, Arabic,
/// Thai — can never produce a character a `keymap.conf` chord is spelled with, so every one of its keys
/// binds by physical position through `latinKey(forKeyCode:)`.
///
/// Deciding per key instead (keeping any produced character that happens to be ASCII) does NOT work,
/// measured against the real layout data: Greek types `;` at the Q position and Hebrew types `/` there,
/// so Latin-spelled letter chords would stay dead on exactly the layouts this serves. Worse, it lets two
/// physical keys collapse onto one chord — Hebrew's `'` position types `,` while its `,` position falls
/// back to `,`; RussianWin's `/` position types `.` against the `.` position's fallback `.` — which
/// fires a binding from a key the user never pressed and swallows the keystroke (the monitor consumes
/// whatever it matches). Resolving the whole layout at once keeps `latinKey`'s one-key-per-position
/// mapping intact, so no two TABLE positions can collapse.
///
/// A key code outside the table keeps what it types, which still aliases the table for the keypad
/// (keypad `5` and the number row both give `"5"`) — deliberate and unchanged by any of this, since the
/// keypad's output does not vary by layout.
///
/// This is a different rule from `InterruptKeystroke.isInterrupt`, which tests the produced character
/// itself (is it a Latin letter?) rather than the layout: that one classifies a single hardcoded key and
/// needs no layout context, while a chord needs the whole ANSI vocabulary including punctuation.
///
/// Returns `nil` when the press carries no usable base key. On a non-ASCII-capable layout that means a
/// position outside the table that produced nothing, plus the ISO section key; a dead key at a TABLE
/// position resolves to its Latin key rather than to `nil`. On an ASCII-capable layout it means anything
/// that produced nothing at all, table position or not — that branch never consults the table.
public func chordKey(forKeyCode keyCode: UInt16, produced: String?, layoutIsASCIICapable: Bool) -> String? {
    // space is a named key (`namedKey(forKeyCode:)` claims keyCode 49); a produced space is not a base key.
    let base = produced?.first.map { String($0).lowercased() }.flatMap { $0 == " " ? nil : $0 }
    guard !layoutIsASCIICapable else { return base }
    if let latin = latinKey(forKeyCode: keyCode) { return latin }
    // the ISO section key — the extra key an ISO keyboard carries and an ANSI one does not — has no
    // position in the table AND types a layout-dependent character, so keeping it would alias whichever
    // table position types the same thing: measured, Ukrainian-PC types `\` there against the ANSI
    // backslash key and Hebrew-PC types `;` there against the ANSI semicolon key. Both would fire one
    // binding from two keys and swallow the keystroke. It cannot spell a chord on a layout resolved by
    // position.
    return keyCode == isoSectionKeyCode ? nil : base
}
