import rookCore
import SwiftUI

// The window-level overlays (quick terminal, palettes, Ctrl-Tab switcher) and the sidebar bottom bar.
extension WindowContentView {
    /// The quick-terminal overlay: the scratch terminal centered at 90% of the window, framed by a
    /// hairline border and shadow so it reads as a distinct floating window over the (undimmed)
    /// content. libghostty renders only the terminal content, so the frame is drawn here. The margin
    /// is a transparent tap-catcher that dismisses on click — no darkening, because the overlay
    /// can't cover the AppKit title bar, so a dim would shade the body but not the chrome. Rendered
    /// only while visible; the surface it hosts is owned by the controller, so hiding keeps the
    /// shell alive.
    /// The window-level overlays (quick terminal, command palettes, Ctrl-Tab switcher) as one layer,
    /// rendered as a ZStack sibling INSIDE the body's root ZStack rather than as body-level `.overlay`s —
    /// so it can be inset below the titlebar and ordered BELOW `customTitlebar` (which a body-level
    /// `.overlay` cannot). Each child is conditional, so when none is showing this is empty (an empty
    /// frame is not hit-testable, so the terminal below stays interactive); each overlay's own
    /// `GeometryReader` fills the inset area. Order here = z-order (switcher on top of palette on top of
    /// quick terminal), matching the previous `.overlay` stacking.
    var windowOverlayLayer: some View {
        ZStack {
            quickTerminalOverlay
            commandPaletteOverlay
            sessionSwitcherOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var quickTerminalOverlay: some View {
        if quickTerminal.isVisible {
            GeometryReader { geo in
                ZStack {
                    // the transparent tap-catcher also carries the `quick-terminal` accessibility id:
                    // a SwiftUI view is exposed in the accessibility tree (the Metal-backed
                    // `QuickTerminalPane` is not), so this is the element control-API tests query for.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { quickTerminal.hide() }
                        .accessibilityElement()
                        .accessibilityIdentifier("quick-terminal")
                    QuickTerminalPane(controller: quickTerminal)
                        .frame(width: geo.size.width * 0.9, height: geo.size.height * 0.9)
                        // solid backing so the quick terminal stays opaque even when the main window
                        // is translucent (its ghostty surface draws transparent under background-opacity=0).
                        .background(terminalColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(radius: 24)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    /// True only for the frontmost window. The palette and session switcher are app-global single
    /// instances (they act on the frontmost store), so only the frontmost window mounts their
    /// overlays — otherwise every open window would render a duplicate overlay, contending for focus
    /// and showing the wrong window's candidates. Uses `activeWindowID` (frontmost-or-first-open, the
    /// same accessor the palette/actions resolve through), so exactly one window matches even before
    /// the first `didBecomeKey` sets `frontmostWindowID`. Reactive: `frontmostWindowID` is observed.
    private var isFrontmost: Bool { library.activeWindowID == windowID }

    /// The command-palette overlay, mounted only while a palette is open in the frontmost window. Its
    /// content (search field + result list) is rebuilt from `palette.mode`.
    @ViewBuilder private var commandPaletteOverlay: some View {
        if isFrontmost, palette.mode != nil {
            CommandPalette(controller: palette, actions: actions)
        }
    }

    /// The Ctrl-Tab session switcher overlay, mounted only while cycling in the frontmost window.
    @ViewBuilder private var sessionSwitcherOverlay: some View {
        if isFrontmost, sessionSwitcher.isActive {
            SessionSwitcherOverlay(switcher: sessionSwitcher, store: store)
        }
    }

    /// Two distinct add controls, source-list style: add a workspace, and a menu
    /// to add a session to the current workspace (default cwd) or a picked directory.
    var bottomBar: some View {
        HStack(spacing: 2) {
            Button {
                actions.newWorkspace()
            } label: {
                Image(systemName: "rectangle.stack.badge.plus")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(helpHint("New Workspace", .newWorkspace))
            .accessibilityLabel("New Workspace")

            Menu {
                Button("New Session") { actions.newSession() }
                Button("Open Directory…") { actions.openDirectory() }
            } label: {
                Image(systemName: "plus.rectangle")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            // a borderless Menu ignores foregroundStyle on its glyph but follows the accent tint.
            .tint(chromeText)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(helpHint("New Session", .newSession))
            .accessibilityLabel("Add session")
            .accessibilityIdentifier("add-session")

            Spacer()

            // an escape hatch shown only while a workspace is focused: names the focused workspace and
            // unfocuses on its ✕ (the primary affordance; the menu/palette "Clear Focus" mirror it).
            if let focused = store.focusedWorkspace {
                Button {
                    actions.clearFocus()
                } label: {
                    HStack(spacing: 4) {
                        Text(focused.name)
                            .lineLimit(1)
                        Image(systemName: "xmark")
                    }
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(chromeText.opacity(0.15)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
                .help("Clear focus")
                .accessibilityLabel("Clear focus")
                .accessibilityIdentifier("focus-pill")
            }

            // flip the sidebar between the workspace tree and the flat flagged working-set list. 2-state
            // glyph (filled in flagged mode); the switch animates via splitRoot's `.animation(value:)`.
            Button {
                actions.toggleFlaggedView()
            } label: {
                let flagged = store.sidebarMode == .flagged
                Image(systemName: flagged ? "flag.fill" : "flag")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            // nothing to show: disable entering an empty flagged view (tree mode + no flags). Stays
            // enabled in flagged mode so the button can always switch back to the tree. The explicit
            // chromeText foregroundStyle defeats SwiftUI's default disabled dimming, so mute it by hand.
            .disabled(store.sidebarMode == .tree && store.flaggedSessions.isEmpty)
            .opacity(store.sidebarMode == .tree && store.flaggedSessions.isEmpty ? 0.35 : 1)
            .help(helpHint(store.sidebarMode == .flagged ? "Show all sessions" : "Show flagged sessions", .toggleFlaggedView))
            .accessibilityLabel("Toggle Flagged View")
            .accessibilityIdentifier("flagged-view-toggle")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        // the add buttons track the terminal theme's foreground, matching the sidebar rows above.
        .foregroundStyle(chromeText)
        // no explicit background: the sidebar is transparent (the window's terminal color shows
        // through), so a `.bar` material here would paint a mismatched darker strip.
    }
}
