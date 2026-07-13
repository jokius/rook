import rookCore
import SwiftUI

// rook draws its OWN titlebar (the system toolbar is gone): the row, its title, and its buttons.
extension WindowContentView {
    /// The titlebar title (first line): the active session's display name, suffixed with the window
    /// name as "session — window" when the window has a custom (user-set) name, so a renamed window
    /// is identifiable at a glance. Auto "window N" names are omitted. "Rook" when nothing is selected.
    var windowTitle: String {
        let session = store.activeSession?.displayName ?? "Rook"
        guard let info = library.windows.first(where: { $0.id == windowID }), info.hasCustomName else {
            return session
        }
        return "\(session) — \(info.name)"
    }

    /// The titlebar subtitle (second line): the focused pane's `subtitleDetail` — its terminal title for
    /// a remote (SSH) session whose local cwd is stale, else its working directory (the split pane's while
    /// it's focused, else the primary's). Shown only in normal mode; compact/hidden drop it.
    private var windowSubtitle: String {
        toolbarMode == .normal ? (store.activeSession?.subtitleDetail ?? "") : ""
    }

    /// The window title at the terminal's leading edge: the session name, plus the cwd subtitle on a
    /// second line only in normal mode (compact drops it for a single short row).
    private var titleLabel: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(windowTitle).fontWeight(.semibold)
            if !windowSubtitle.isEmpty {
                Text(windowSubtitle)
                    .font(.caption)
                    .foregroundStyle(chromeText.opacity(0.6))
            }
        }
    }

    /// The window chrome above the terminal: the full custom titlebar row, or — in hidden mode — an
    /// invisible ~3px top drag strip and nothing else (no row, and `WindowAppearance.sync` also drops the
    /// traffic lights) so the terminal runs full-bleed while the window stays movable + double-click-zoomable.
    @ViewBuilder var customTitlebar: some View {
        if toolbarMode == .hidden {
            // only the top ~3px loses click-through (the accepted cost) — kept thin so it doesn't cover the
            // terminal's first row (window-padding-y = 6), which would otherwise swallow clicks meant to
            // select it; it still keeps the standard title-bar gestures via the same `WindowControlArea`.
            Color.clear
                .frame(height: 3)
                .frame(maxWidth: .infinity)
                // Color.clear is hit-testable in SwiftUI, so it would swallow the mouseDown before it
                // reaches the WindowControlArea behind it — opt out (like the titlebarRow spacers) so the
                // strip's drag/double-click-zoom gestures fall through to the AppKit view.
                .allowsHitTesting(false)
                .background { WindowControlArea() }
        } else {
            titlebarRow
        }
    }

    /// Custom titlebar row replacing the system toolbar: the sidebar toggle pinned to the sidebar's
    /// trailing edge (by the divider), the title at the terminal's start, and the split / quick-terminal
    /// buttons at the trailing edge. Positions track `sidebarWidth`; the left inset clears the system
    /// traffic lights.
    private var titlebarRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 78).allowsHitTesting(false) // system traffic lights
            if store.sidebarVisible {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    sidebarToggleButton.labelStyle(.iconOnly)
                }
                .frame(width: max(40, CGFloat(store.sidebarWidth) - 78))
                Color.clear.frame(width: 11).allowsHitTesting(false) // 1px divider + gap to the title
            } else {
                sidebarToggleButton.labelStyle(.iconOnly)
                Spacer().frame(width: 12)
            }
            titleLabel
                // the title text falls through to the drag/zoom layer behind it (see `.background` below),
                // so double-clicking it zooms and dragging it moves the window — the rest of the row is
                // empty spacers (already non-hittable) and the buttons, which keep their own clicks.
                .allowsHitTesting(false)
            if attentionButtonEnabled {
                attentionButton.labelStyle(.iconOnly).padding(.leading, 10)
            }
            Spacer(minLength: 12)
            HStack(spacing: 14) {
                scratchButton.labelStyle(.iconOnly)
                splitButton.labelStyle(.iconOnly)
                // separates the per-session view toggles (scratch/split) from the window-level quick terminal.
                Rectangle().fill(chromeText.opacity(0.25)).frame(width: 1, height: 16)
                quickTerminalButton.labelStyle(.iconOnly)
            }
            .padding(.trailing, 14)
        }
        .buttonStyle(.plain)
        // tint the title text and the toolbar buttons with the terminal theme's foreground so the
        // chrome tracks the theme (the cwd subtitle dims itself to 0.6 over this).
        .foregroundStyle(chromeText)
        // larger icons in the normal row, smaller in compact (the row isn't drawn in hidden mode; imageScale hits the
        // SF Symbols, not the title text).
        .imageScale(toolbarMode == .normal ? .large : .medium)
        .frame(height: titlebarHeight)
        .frame(maxWidth: .infinity)
        // make the header behave like a standard title bar: single-click drag moves the window, double-click
        // runs the user's configured title-bar action (zoom/minimize/none). The layer sits BEHIND the row,
        // so the buttons render in front and keep their clicks; the empty spacers + the title text opt out of
        // hit-testing (above) so their region falls through to it. Custom titlebar = no native title-bar
        // double-click handling, hence this.
        .background { WindowControlArea() }
    }

    /// A tooltip string with the action's current shortcut appended in parentheses (e.g. `Toggle
    /// Sidebar (⌃⌘S)`), or just the base text when the action has no configured shortcut. Keeps the
    /// toolbar/sidebar hints in lockstep with the keymap — a rebind shows the new chord, an unbound
    /// action shows none — via the SAME `AppActions.shortcutGlyph` resolver the action palette uses.
    func helpHint(_ base: String, _ action: BuiltinAction) -> String {
        guard let glyph = actions.shortcutGlyph(for: action) else { return base }
        return "\(base) (\(glyph))"
    }

    /// Our own sidebar show/hide toggle (the custom split has no system one). Animated collapse.
    private var sidebarToggleButton: some View {
        Button {
            actions.toggleSidebar()
        } label: {
            Label("Toggle Sidebar", systemImage: "sidebar.left")
        }
        .help(helpHint("Toggle Sidebar", .toggleSidebar))
        .accessibilityIdentifier("sidebar-toggle-button")
    }

    private var splitButton: some View {
        let isSplit = store.activeSession?.isSplit ?? false
        let hasSplit = store.activeSession?.hasSplit ?? false
        let splitFocused = store.activeSession?.splitFocused ?? false
        // filled = pane visible, outline = hidden. no split: an empty two-pane outline. split shown: both
        // panes filled. collapsed to a single pane (hasSplit but not shown): only the VISIBLE pane's half
        // is filled — left for the primary, right for the split pane (`splitFocused` is the shown one when
        // hidden) — so the glyph tells you which pane is up and that the other is parked. `a11y` mirrors the
        // four states for XCUITest, which can't read the symbol name (like the attention bell's value).
        let symbol: String
        let a11y: String
        if !hasSplit {
            symbol = "rectangle.split.2x1"; a11y = "none"
        } else if isSplit {
            symbol = "rectangle.split.2x1.fill"; a11y = "both"
        } else if splitFocused {
            symbol = "rectangle.righthalf.filled"; a11y = "right"
        } else {
            symbol = "rectangle.lefthalf.filled"; a11y = "left"
        }
        return Button {
            actions.toggleSplit()
        } label: {
            // a Label (icon + title) so the toolbar's "Icon and Text" mode has text to show; the title
            // is hidden in the default icon-only mode.
            Label("Split", systemImage: symbol)
        }
        .help(helpHint(isSplit ? "Hide split" : (hasSplit ? "Show split" : "Split right"), .toggleSplit))
        .disabled(store.activeSession == nil)
        .accessibilityValue(a11y)
        .accessibilityIdentifier("split-toggle")
    }

    /// Toolbar button that toggles the active session's scratch terminal — a third, full-overlay login
    /// shell, kept alive when hidden. 2-state glyph (filled while shown): unlike the split there is no
    /// "hidden but exists" indicator, since the shell's own `exit` clears it and the next show is fresh.
    private var scratchButton: some View {
        let active = store.activeSession?.scratchActive ?? false
        return Button {
            actions.toggleScratch()
        } label: {
            Label("Scratch", systemImage: active ? "rectangle.inset.filled" : "rectangle")
        }
        .help(helpHint(active ? "Hide scratch terminal" : "Show scratch terminal", .toggleScratch))
        .disabled(store.activeSession == nil)
        .accessibilityIdentifier("scratch-toggle")
    }

    /// Toolbar button (next to the split toggle) that toggles the quick terminal: a single
    /// scratch terminal overlaid at 90% of the window, on top of the sidebar and terminal.
    /// Click the button again or the surrounding margin to hide; the shell stays alive until quit.
    private var quickTerminalButton: some View {
        Button {
            quickTerminal.toggle()
        } label: {
            Label("Quick Terminal", systemImage: "terminal")
        }
        .help(helpHint("Quick Terminal", .quickTerminal))
        .accessibilityIdentifier("quick-terminal-toggle")
    }

    /// Title-bar bell reflecting the window's attention state at a glance (opt-in, gated by the
    /// `attentionButtonEnabled` mirror). Three states from `store.attentionSessions`: empty → a dimmed
    /// disabled outline bell; non-empty with nothing blocked → a plain enabled bell in `chromeText`; any
    /// blocked session → a filled bell tinted the blocked-status color. No count, no pulse. Click opens
    /// the `.attention` palette. Reading `store.attentionSessions` in the body registers the per-session
    /// `agentIndicator` observation, so the glyph re-renders live as a status changes. `.accessibilityValue`
    /// (none|attention|blocked) exposes the otherwise-unobservable bell↔bell.fill state to XCUITest,
    /// mirroring `StatusIconView`'s state-name value.
    private var attentionButton: some View {
        let sessions = store.attentionSessions
        let blocked = sessions.contains { $0.agentIndicator.status == .blocked }
        let empty = sessions.isEmpty
        return Button {
            actions.toggleAttentionPalette()
        } label: {
            Label("Attention", systemImage: blocked ? "bell.fill" : "bell")
        }
        .foregroundStyle(blocked ? Color(nsColor: GhosttyApp.shared.blockedStatusColor) : chromeText)
        .opacity(empty ? 0.35 : 1)
        .disabled(empty)
        .help(helpHint(empty ? "No sessions need attention" : "Show sessions that need attention", .showAttention))
        .accessibilityIdentifier("attention-button")
        .accessibilityValue(empty ? "none" : (blocked ? "blocked" : "attention"))
    }
}
