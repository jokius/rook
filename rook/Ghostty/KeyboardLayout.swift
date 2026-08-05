import AppKit
import Carbon

/// The character a physical key would produce on the user's ASCII-capable keyboard layout — what makes a
/// shortcut survive a Cyrillic (or Greek, Hebrew, Arabic) layout. See `rookCore.KeyCodepoint` for why the
/// unshifted codepoint is what decides whether a TUI program sees `Ctrl+C` at all.
///
/// `TISCopyCurrentASCIICapableKeyboardLayoutInputSource` is the layout macOS itself falls back on for
/// shortcuts (usually ABC/US, but a Dvorak user's ASCII layout is Dvorak — which is why this asks the OS
/// instead of hardcoding QWERTY). Deliberately NOT cached: it is only ever called for a modified keystroke
/// whose character is non-ASCII, so it runs at human typing speed on Cyrillic Ctrl-chords and never in a
/// text-input hot path — a cache would only add a layout-switch invalidation to get wrong.
enum KeyboardLayout {
    /// Whether the ACTIVE keyboard layout can type ASCII at all — the one bit
    /// `chordKey(forKeyCode:produced:layoutIsASCIICapable:)` branches on to decide whether a keymap chord
    /// resolves by produced character or by physical position. Note the different input source from
    /// `asciiCodepoint`: this asks about the layout the user is CURRENTLY typing on, not the ASCII layout
    /// macOS would fall back to.
    ///
    /// Read fresh on every key press, like the codepoint above and for the same reason — it costs well
    /// under a microsecond, so it needs no cache and no `kTISNotifySelectedKeyboardInputSourceChanged`
    /// observer and cannot go stale mid-session. Falls back to true (bind by produced character) when the
    /// layout cannot be resolved, which is how every Latin layout already behaves.
    ///
    /// This covers the two MONITOR-driven paths only — custom commands and `undo_close`. Every other
    /// built-in rides an AppKit menu key equivalent, which resolves on its own.
    static var isASCIICapable: Bool {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable)
        else { return true }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }

    static func asciiCodepoint(forKeyCode keyCode: UInt16) -> UInt32? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        // no modifiers: the BASE character of the key. kUCKeyTranslateNoDeadKeysMask keeps a dead key
        // (a latin-but-not-ASCII layout has them) from swallowing the translation into a 0-length result.
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return errSecParam }
            return UCKeyTranslate(layout,
                                  keyCode,
                                  UInt16(kUCKeyActionDown),
                                  0,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                  &deadKeyState,
                                  chars.count,
                                  &length,
                                  &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return UInt32(chars[0])
    }
}
