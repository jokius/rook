import Foundation

/// TerminalText sanitizes strings a terminal program reports over OSC sequences — the window title
/// (OSC 0/1/2) and the working directory (OSC 7) — before rook stores them on a `Session`. Those
/// values are attacker-influenceable (a remote SSH host or any program's output sets them) and flow,
/// unquoted, into a `/bin/sh -c` line via the `{AGT_SESSION_NAME}`/`{AGT_SESSION_PWD}` custom-command
/// tokens, so a control character — a newline above all, which `sh -c` reads as a command separator —
/// must never survive into the stored value. A title or a directory path never legitimately contains
/// a control character, so stripping the whole C0 range is lossless for real input.
///
/// This does NOT make raw `{AGT_X}` interpolation safe against visible shell metacharacters (`;`,
/// `$()`, backticks); those are legitimate in titles/paths and are the caller's concern via the
/// shell-quoted `$AGT_X` environment form. This closes only the invisible control-character vector.
public enum TerminalText {
    /// Strip the C0 control range (U+0000–U+001F, including tab/newline/carriage-return) and DEL
    /// (U+007F) from an OSC-reported title or working directory; every other scalar is preserved.
    /// The common case (no control characters, which is every real title/path) returns the input
    /// unchanged with no allocation, since these callbacks run on every OSC redraw.
    public static func sanitized(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return value }
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars where scalar.value >= 0x20 && scalar.value != 0x7F {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Strip the progress marker a coding agent prefixes to the OSC title it reports — Claude Code writes
    /// `✳ Implement the parser` at rest and cycles a braille spinner (`⠋ …`, `⠙ …`, `⠹ …`) while it works.
    /// The session's agent is shown by the sidebar's agent LOGO instead (`AgentKind`), so the marker is
    /// noise in the name — and stripping it at ingest collapses every spinner frame to the SAME title, so
    /// `applyTitle`'s equality guard swallows the per-frame re-emits that used to churn the sidebar.
    ///
    /// Conservative by construction: it strips a leading run of spinner/asterisk-dingbat scalars ONLY when
    /// whitespace and a non-blank remainder follow. A title that merely BEGINS with one of these glyphs
    /// (`✳️-marked branch`), an emoji title, a `user@host:~/dir` SSH title, and a bare marker with no text
    /// all pass through untouched.
    public static func withoutAgentMarker(_ value: String) -> String {
        let scalars = value.unicodeScalars
        // the FIRST scalar must be a marker proper: a lone variation selector leading a title is not one.
        guard let first = scalars.first, isAgentMarker(first) else { return value }
        let rest = scalars.drop { isAgentMarker($0) || isVariationSelector($0) }
        guard let next = rest.first, next.properties.isWhitespace else { return value }
        let body = String(String.UnicodeScalarView(rest)).trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? value : body
    }

    /// The marker scalars: the braille block (U+2800–U+28FF — every spinner frame a TUI cycles) and the
    /// asterisk dingbats (U+2731–U+273D, which include Claude Code's `✳` U+2733). Deliberately NOT ASCII
    /// `*` — a title legitimately starts with one (a glob, a footnote) — and not emoji.
    private static func isAgentMarker(_ scalar: Unicode.Scalar) -> Bool {
        (0x2800...0x28FF).contains(scalar.value) || (0x2731...0x273D).contains(scalar.value)
    }

    /// A text/emoji presentation selector (U+FE0E/U+FE0F), which may trail a marker (`✳️`) and would
    /// otherwise leave the separator check looking at the selector instead of the space.
    private static func isVariationSelector(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0xFE0E || scalar.value == 0xFE0F
    }
}
