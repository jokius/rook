import Foundation

/// Which codepoint agterm reports to libghostty as a keystroke's "unshifted codepoint" — the field that
/// decides how a SHORTCUT (Ctrl-C, Alt-B) is encoded into the pty.
///
/// A non-latin layout breaks shortcuts in TUI programs, and only there. libghostty has two encoders:
/// the legacy one maps a Ctrl chord through the PHYSICAL key, so `Ctrl+C` on a Cyrillic layout still
/// sends `0x03` and the shell interrupts; but the kitty keyboard protocol — which Claude Code, vim and
/// tmux turn on — reports the key as this unshifted codepoint, so a Cyrillic layout sends
/// `CSI 1089;5u` ("Ctrl + с", U+0441) instead of `CSI 99;5u` ("Ctrl + c"), and the program never sees an
/// interrupt. (The latin key rides along in an optional "base layout" field that virtually no program
/// reads.) Verified end to end against a real keystroke, both layouts, both encoders.
///
/// The fix every terminal converges on: when a shortcut modifier is held and the layout produced a
/// non-ASCII character, report the character the SAME physical key would produce on the user's
/// ASCII-capable layout instead. So the shortcut travels by key POSITION, while ordinary typing — no
/// modifier — keeps reporting the real character and is left completely alone.
public enum KeyCodepoint {
    /// `latin` is the ASCII-capable layout's character for the same physical key (nil when it cannot be
    /// resolved). It wins ONLY when the layout's own character is non-ASCII, so a latin layout — including
    /// Dvorak/Colemak, where the user's key POSITIONS are deliberately their own — is never rewritten.
    /// A non-printable latin result is refused too: it could only make the encoding worse.
    public static func unshifted(layout: UInt32, latin: UInt32?) -> UInt32 {
        guard layout > 0x7F, let latin, (0x20...0x7E).contains(latin) else { return layout }
        return latin
    }
}
