import Testing
@testable import rookCore

@Suite("KeyCodepoint")
struct KeyCodepointTests {
    // the bug: a Cyrillic layout reports U+0441 for the C key, so a kitty-protocol program sees "Ctrl + с"
    // and never recognizes the interrupt. The latin character of the same physical key is what it must get.
    @Test("a non-latin letter is reported as its ASCII-capable-layout key")
    func nonLatinFallsBackToLatin() {
        #expect(KeyCodepoint.unshifted(layout: 0x0441, latin: 0x63) == 0x63)  // с -> c
        #expect(KeyCodepoint.unshifted(layout: 0x0432, latin: 0x64) == 0x64)  // в -> d
    }

    // a latin layout must never be rewritten — on Dvorak/Colemak the user's key POSITIONS are the point,
    // and remapping them to QWERTY would move every one of their shortcuts.
    @Test("an ASCII character keeps its own value")
    func asciiIsLeftAlone() {
        #expect(KeyCodepoint.unshifted(layout: 0x63, latin: 0x6A) == 0x63)
        #expect(KeyCodepoint.unshifted(layout: 0x2E, latin: 0x76) == 0x2E)
    }

    @Test("an unresolvable or non-printable latin key leaves the layout value untouched")
    func refusesUnusableFallback() {
        #expect(KeyCodepoint.unshifted(layout: 0x0441, latin: nil) == 0x0441)
        #expect(KeyCodepoint.unshifted(layout: 0x0441, latin: 0) == 0x0441)
        #expect(KeyCodepoint.unshifted(layout: 0x0441, latin: 0x0431) == 0x0441)
    }
}
