import rookCore
import AppKit

/// ⌘W ownership between rook's File ▸ Close Session and the stock File ▸ Close (`performClose:`).
///
/// SwiftUI hands the stock item a ⌘W key equivalent the moment rook's own item vacates the chord — a
/// `map cmd+<other> close_session` plus a keymap reload is enough. Putting `close_session` back on ⌘W does
/// NOT reclaim it: SwiftUI defers its menu rebuild to the next app ACTIVATION, and that rebuild resolves the
/// key-equivalent collision by dropping the shortcut from its OWN item — Close Session ends up keyless while
/// ⌘W closes the whole window, until the app is relaunched.
///
/// So rook asserts the split from AppKit instead of leaving it to SwiftUI's one-time conflict resolution.
/// Re-run at launch, on `.rookKeymapChanged`, on `didBecomeActive` (async, so it lands after SwiftUI's
/// rebuild), and on menu tracking — the same "a one-shot does not stick" shape as
/// `removeNativeFullScreenMenuItem`, and for the same reason: there is no SwiftUI API for either half.
extension AppDelegate {
    /// Re-assert the ⌘W split from the live keymap. A no-op before the scene `.task` hands over the settings
    /// model — the menu is still at its shipped defaults then, which already agree with the keymap.
    func reconcileCloseSessionChord() {
        guard let keymap = settingsModel?.keymap else { return }
        AppDelegate.applyCloseSessionChord(keymap, in: NSApp.mainMenu)
    }

    /// Split ⌘W between rook's Close Session item and the stock `performClose:` one, following `keymap`.
    /// Operates on whichever submenu holds BOTH; a submenu missing either is left alone.
    ///
    /// The stock item may hold ⌘W only while NO built-in resolves to it. Deciding that from `close_session`
    /// alone is not enough: `parseKeymap` rejects a chord only when two DISTINCT actions claim it, so
    /// `map cmd+e close_session` plus `map cmd+w new_session` is a legal keymap in which another action
    /// legitimately owns ⌘W — arming the stock item there would advertise the chord twice and let SwiftUI's
    /// next rebuild unbind rook's own item, the very failure this reconcile exists to prevent.
    ///
    /// rook's item is a SwiftUI closure button with no distinguishing selector, so it can only be matched by
    /// title; scoping that match to the submenu that owns `performClose:` keeps it narrow.
    @MainActor
    static func applyCloseSessionChord(_ keymap: Keymap, in mainMenu: NSMenu?) {
        let closeSessionOwns = keymap.equivalent(for: .closeSession) == commandW
        let anyBuiltinOwns = BuiltinAction.allCases.contains { keymap.equivalent(for: $0) == commandW }
        let closeSelector = #selector(NSWindow.performClose(_:))
        for topItem in mainMenu?.items ?? [] {
            guard let submenu = topItem.submenu,
                  let stockClose = submenu.items.first(where: { $0.action == closeSelector }),
                  let ours = submenu.items.first(where: { $0.title == closeSessionItemTitle })
            else { continue }
            // our item carries ⌘W exactly while close_session owns it. Clearing a STALE one matters because
            // SwiftUI defers its rebuild to the next activation, so straight after a reload that rebound
            // close_session away our item still advertises the chord the stock item is about to take, and the
            // File menu would show ⌘W twice — one of them on the close-the-whole-window item.
            if closeSessionOwns {
                ours.keyEquivalent = "w"
                ours.keyEquivalentModifierMask = .command
            } else if ours.keyEquivalent == "w", ours.keyEquivalentModifierMask == .command {
                ours.keyEquivalent = ""
                ours.keyEquivalentModifierMask = []
            }
            stockClose.keyEquivalent = anyBuiltinOwns ? "" : "w"
            stockClose.keyEquivalentModifierMask = anyBuiltinOwns ? [] : .command
        }
    }

    /// The File-menu title of rook's own close-the-session item (`Button("Close Session")` in
    /// `rookApp+Menus.swift`) — the only handle this reconcile has on a SwiftUI closure button.
    private static let closeSessionItemTitle = "Close Session"
    private static let commandW = Chord(mods: [.command], key: "w")
}
