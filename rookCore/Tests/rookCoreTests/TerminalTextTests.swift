import Testing
@testable import rookCore

struct TerminalTextTests {
    @Test func cleanStringUnchanged() {
        #expect(TerminalText.sanitized("user@host: ~/dev (main)") == "user@host: ~/dev (main)")
    }

    @Test func stripsNewlineAndCarriageReturn() {
        // the security-relevant case: a newline in an unquoted {AGT_X} splice is an sh -c command separator.
        #expect(TerminalText.sanitized("title\ninjected") == "titleinjected")
        #expect(TerminalText.sanitized("a\rb") == "ab")
        #expect(TerminalText.sanitized("a\r\nb") == "ab")
    }

    @Test func stripsTabNulEscAndDel() {
        #expect(TerminalText.sanitized("a\tb") == "ab")
        #expect(TerminalText.sanitized("a\u{00}b") == "ab")
        #expect(TerminalText.sanitized("a\u{1B}[31mb") == "a[31mb")
        #expect(TerminalText.sanitized("a\u{7F}b") == "ab")
    }

    @Test(arguments: 0..<0x20)
    func stripsEveryC0ControlCharacter(_ code: Int) {
        let scalar = Unicode.Scalar(code)!
        #expect(TerminalText.sanitized("a\(scalar)b") == "ab")
    }

    @Test func preservesPrintableUnicodeAndSpace() {
        #expect(TerminalText.sanitized("café 🚀 ~/项目") == "café 🚀 ~/项目")
    }

    @Test func emptyStaysEmpty() {
        #expect(TerminalText.sanitized("") == "")
    }

    @Test(arguments: [
        ("\u{2733} Implement the parser", "Implement the parser"), // ✳ — Claude Code at rest
        ("\u{2733}\u{FE0F} Implement the parser", "Implement the parser"), // with the emoji variation selector
        ("\u{280B} Thinking…", "Thinking…"), // ⠋ — a braille spinner frame
        ("\u{2839} Running tests", "Running tests"), // a different frame collapses to the SAME title
        ("\u{2733}  double space", "double space"),
        ("\u{273B} starry", "starry"),
    ])
    func stripsTheLeadingAgentMarker(_ raw: String, _ expected: String) {
        #expect(TerminalText.withoutAgentMarker(raw) == expected)
    }

    @Test(arguments: [
        "konayre@Mac: ~/myProjects/rook", // an SSH / prompt title
        "* wildcard build", // ASCII asterisk is NOT a marker — a title may legitimately start with one
        "🚀 deploy", // an emoji title is left alone
        "\u{2733}no-space", // no separator after the marker: not the agent's format, so hands off
        "\u{2733}", // a bare marker with no text: nothing to fall back to, keep it
        "\u{2733} ", // marker + whitespace only
        "make test",
        "",
    ])
    func leavesAnOrdinaryTitleAlone(_ raw: String) {
        #expect(TerminalText.withoutAgentMarker(raw) == raw)
    }

    @Test func isIdempotent() {
        let once = TerminalText.withoutAgentMarker("\u{2733} Implement the parser")
        #expect(TerminalText.withoutAgentMarker(once) == once)
    }

    @Test func stripsOnlyAtTheStart() {
        #expect(TerminalText.withoutAgentMarker("rename \u{2733} to star") == "rename \u{2733} to star")
    }
}
