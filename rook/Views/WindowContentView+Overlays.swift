import rookCore
import SwiftUI

// The window-level overlays (quick terminal, palettes, Ctrl-Tab switcher) and the sidebar bottom bar.
extension WindowContentView {
    /// The quick-terminal overlay: the scratch terminal centered at 90% of the window, framed by a
    /// hairline border and shadow so it reads as a distinct floating window over the content.
    /// libghostty renders only the terminal content, so the frame is drawn here. The margin is a
    /// tap-catcher that dismisses on click and carries the same backdrop mute as a floating overlay.
    /// A dark SCRIM was rejected here and stays rejected: this layer is inset below the AppKit title
    /// bar, so anything painted over the body raises its opacity against unchanged chrome. The mute
    /// wash is neutral at full window opacity and `muteWashOpacity` scales it down under translucency,
    /// which shrinks that seam without closing it. Rendered only while visible; the surface it hosts is
    /// owned by the controller, so hiding keeps the shell alive.
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
            // the dashboard is the topmost window overlay: opening it closes the three above (mirrors the
            // zoom lifecycle), so ordering only settles the empty case, but it renders last for clarity.
            dashboardOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var quickTerminalOverlay: some View {
        if quickTerminal.isVisible {
            GeometryReader { geo in
                ZStack {
                    // the tap-catcher also carries the `quick-terminal` accessibility id: a SwiftUI view is
                    // exposed in the accessibility tree (the Metal-backed `QuickTerminalPane` is not), so
                    // this is the element control-API tests query for. It spans the sidebar too, unlike the
                    // overlay's pane-scoped backdrop.
                    (store.activeSession.map { washColor(for: $0) } ?? terminalColor)
                        .opacity(muteWashOpacity)
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

    /// Where the terminal area starts ON SCREEN: the sidebar column plus its 1pt divider, or 0 whenever no
    /// sidebar is showing. The palette and the switcher center their panel over THAT area rather than over
    /// the whole window, which otherwise reads as off-center whenever the sidebar is up. The palette's
    /// scrim stays full width and dismisses on a click anywhere; the switcher's is click-through by design
    /// and ends on Ctrl release.
    ///
    /// Zoom and the dashboard are why `store.sidebarVisible` alone is not the answer: both leave that flag
    /// set while COVERING the sidebar (zoom drops the deck to opacity 0, the dashboard paints over it), so
    /// reading the flag alone would shift a panel by half a sidebar that is not on screen.
    private var terminalAreaInset: Double {
        guard store.sidebarVisible, terminalZoom.target == nil, !dashboard.isOpen else { return 0 }
        return store.sidebarWidth + 1
    }

    /// The command-palette overlay, mounted only while a palette is open in the frontmost window. Its
    /// content (search field + result list) is rebuilt from `palette.mode`.
    @ViewBuilder private var commandPaletteOverlay: some View {
        if isFrontmost, palette.mode != nil {
            CommandPalette(controller: palette, actions: actions, terminalAreaInset: terminalAreaInset)
        }
    }

    /// The Ctrl-Tab session switcher overlay, mounted only while cycling in the frontmost window.
    @ViewBuilder private var sessionSwitcherOverlay: some View {
        if isFrontmost, sessionSwitcher.isActive {
            SessionSwitcherOverlay(switcher: sessionSwitcher, store: store, terminalAreaInset: terminalAreaInset)
        }
    }

    /// Two distinct add controls, source-list style: add a workspace, and a menu
    /// to add a session to the current workspace (default cwd) or a picked directory.
    var bottomBar: some View {
        HStack(spacing: 2) {
            if shows(.newWorkspace) {
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
            }

            if shows(.newSession) {
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
            }

            Spacer()

            // apply or suspend the workspace focus filter WITHOUT losing the marked set. 2-state grid
            // glyph (filled while filtering), disabled with nothing marked — there is nothing to filter
            // to. It is both the indicator and the control, and the only affordance that still works
            // while the filter is OFF: the pill this replaced rendered the EFFECTIVE focus, so an
            // involuntary jump that dropped the flag took the way back with it.
            if shows(.focusFilter) {
                Button {
                    actions.toggleFocusFilter()
                } label: {
                    Image(systemName: store.focusEnabled ? "square.grid.2x2.fill" : "square.grid.2x2")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                // the explicit chromeText foregroundStyle defeats SwiftUI's default disabled dimming, so
                // mute it by hand — the same rule as the flagged toggle below.
                .disabled(store.focusedWorkspaceIDs.isEmpty)
                .opacity(store.focusedWorkspaceIDs.isEmpty ? 0.35 : 1)
                .help(helpHint(store.focusEnabled ? "Show all workspaces" : "Show only focused workspaces", .toggleWorkspaceFilter))
                .accessibilityLabel("Toggle Workspace Filter")
                .accessibilityIdentifier("focus-filter-toggle")
                // an SF Symbol is not accessibility-observable and the pill that used to report the state
                // is gone, so this value is the ONLY accessible read of whether the filter applies.
                .accessibilityValue(store.focusEnabled ? "on" : "off")
            }

            // flip the sidebar between the workspace tree and the flat flagged working-set list. 2-state
            // glyph (filled in flagged mode); the switch animates via splitRoot's `.animation(value:)`.
            if shows(.flaggedView) {
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
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        // the add buttons track the terminal theme's foreground, matching the sidebar rows above.
        .foregroundStyle(chromeText)
        // no explicit background: the sidebar is transparent (the window's terminal color shows
        // through), so a `.bar` material here would paint a mismatched darker strip.
    }
}
