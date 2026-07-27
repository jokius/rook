import AppKit
import Foundation
import rookCore

/// `ControlServer`'s keymap READ arm. The write arm (`keymap.reload`) lives with the other app-command
/// witnesses in `ControlServer+SessionActions.swift`; this one is split out because the live menu-bar walk
/// is the only genuinely AppKit-bound half of `keymap.list` and that file is at its size limit.
extension ControlServer {
    /// The read side of `keymap.reload`: what the keymap resolved, plus what the menu bar is actually
    /// dispatching. The two halves can disagree — SwiftUI defers its menu rebuild to the next app
    /// activation, so a chord correct in the model can be stale in the menu, which is the divergence a
    /// bare model listing cannot show. App-global like `keymap.reload`, so no `--window` selector.
    func listKeymap() -> ControlResponse {
        let payload = ControlKeymap.project(keymap: settingsModel.keymap,
                                            diagnostics: settingsModel.keymapDiagnostics,
                                            path: settingsModel.keymapPath,
                                            menu: ControlServer.liveMenuKeyEquivalents())
        return ControlResponse(ok: true, result: ControlResult(keymap: payload))
    }

    /// Every menu-bar item carrying a key equivalent, rendered in the same kitty syntax the keymap uses so
    /// a caller can compare the two lists directly. Only the app target can read `NSApp.mainMenu`, so this
    /// is the app-side half of the otherwise host-free `keymap.list` payload.
    @MainActor
    private static func liveMenuKeyEquivalents() -> [ControlKeymapMenuItem] {
        (NSApp.mainMenu?.items ?? []).flatMap { topItem in
            topItem.submenu.map { collectKeyEquivalents(in: $0, menu: topItem.title) } ?? []
        }
    }

    /// Every key equivalent in `submenu`, RECURSING into nested submenus. AppKit's own
    /// `performKeyEquivalent` recurses, so a chord one level down is just as live and can just as easily
    /// shadow a rook binding — App ▸ Services is the reachable case, since its entries carry whatever
    /// shortcuts the user assigned in System Settings. Reporting only the top level would let a caller
    /// compare the two lists and conclude nothing holds a chord when something does.
    ///
    /// `menu` stays the TOP-LEVEL menu's title throughout, so a nested item is still attributed to the
    /// menu-bar entry the reader can find it under.
    ///
    /// `private` where upstream keeps it internal: upstream un-privated it so an app-target unit test could
    /// drive it over a hand-built nested menu, and rook has no app-target test bundle to write that in
    /// (`project.yml` declares only the XCUITest target). Widen it again if one ever lands.
    @MainActor
    private static func collectKeyEquivalents(in submenu: NSMenu, menu: String) -> [ControlKeymapMenuItem] {
        submenu.items.flatMap { item -> [ControlKeymapMenuItem] in
            var found: [ControlKeymapMenuItem] = []
            if !item.keyEquivalent.isEmpty {
                found.append(ControlKeymapMenuItem(menu: menu, title: item.title,
                                                   chord: chordSyntax(for: item),
                                                   selector: item.action.map(NSStringFromSelector),
                                                   enabled: item.isEnabled ? nil : false))
            }
            if let nested = item.submenu { found += collectKeyEquivalents(in: nested, menu: menu) }
            return found
        }
    }

    /// An `NSMenuItem`'s key equivalent in kitty syntax (`cmd+shift+e`), matching `Chord.displayString`'s
    /// modifier order so the two render identically and a caller can compare them as strings.
    ///
    /// Two AppKit spellings have to be translated or the chord comes out uncomparable. Arrows and
    /// return/tab/space/delete arrive as function-key or control CHARACTERS, which would render the key
    /// blank (`cmd+opt+` for what the keymap calls `cmd+opt+up`), so they go through
    /// `namedKey(forKeyEquivalent:)`. And a shift-typed equivalent arrives as the SHIFTED character with
    /// `.shift` set (⇧E is `"E"`), so an ordinary key is lowercased to the unshifted base the grammar uses.
    ///
    /// The globe/fn modifier has NO keymap spelling (the grammar knows ctrl/cmd/opt/shift only), but it is
    /// rendered as `fn+` anyway: this section reports what the menu bar really carries, and dropping the
    /// modifier would print AppKit's own ⌥⌘F-style items as bare unmodified keys, which reads as a binding
    /// that does not exist. A `fn+` chord simply never matches an action's chord, which is correct.
    @MainActor
    private static func chordSyntax(for item: NSMenuItem) -> String {
        let mods = item.keyEquivalentModifierMask
        let key = item.keyEquivalent
        // an UPPERCASE key equivalent carries shift implicitly, whether or not the mask says so: AppKit
        // matches `"C"` + [.command] against ⇧⌘C and not ⌘C. rook's own items never spell it that way
        // (`toShortcut` always puts shift in the mask), but this walk reports third-party items too, and
        // lowercasing without adding shift would name a chord that item can never fire.
        let impliedShift = key.count == 1 && key.first?.isUppercase == true
        var parts: [String] = []
        if mods.contains(.function) { parts.append("fn") }
        if mods.contains(.control) { parts.append("ctrl") }
        if mods.contains(.command) { parts.append("cmd") }
        if mods.contains(.option) { parts.append("opt") }
        if mods.contains(.shift) || impliedShift { parts.append("shift") }
        parts.append(namedKey(forKeyEquivalent: key) ?? key.lowercased())
        return parts.joined(separator: "+")
    }
}
