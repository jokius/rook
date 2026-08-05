import rookCore
import AppKit
import SwiftUI

/// One selectable palette entry: a title (and optional subtitle, e.g. a session's cwd), an optional
/// keyboard-shortcut hint shown right-aligned, plus the closure to run when chosen.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    /// The action's keyboard shortcut hint shown right-aligned, nil for items with no shortcut.
    /// Rebindable built-ins read the live keymap (`AppActions.shortcutGlyph`) so it tracks rebinds and
    /// render as macOS menu glyphs (e.g. `⌘⇧E`); custom commands show their raw kitty shortcut string
    /// (e.g. `cmd+shift+e`).
    let shortcut: String?
    /// A small trailing badge label (e.g. `custom` for user-defined keymap commands), nil for none.
    let badge: String?
    /// A leading agent-status glyph (the attention palette's rows carry it), nil for items with no
    /// status — only the `.attention` palette sets it, so the other palettes render no glyph.
    let status: AgentStatus?
    /// Per-call `#rrggbb` glyph-tint override for the leading status glyph (the session's
    /// `AgentIndicator.color`), so the attention row matches the sidebar; nil = the default status color.
    let statusColor: String?
    /// Per-call glyph SHAPE override (the session's `AgentIndicator.shape`), carried for the same reason
    /// as `statusColor`: the row has to draw the same glyph the sidebar does, or a caller who set a shape
    /// sees it in one place and the semantic default in the other.
    let statusShape: StatusShape?
    /// Fired when this item BECOMES the selection (keyboard navigation), distinct from `run` (Enter/
    /// click). Only the `.themes` palette sets it — it drives the live theme preview; nil everywhere
    /// else, so the other palettes have no selection side effect.
    let onSelect: (() -> Void)?
    let run: () -> Void

    init(id: String? = nil, title: String, subtitle: String? = nil, shortcut: String? = nil,
         badge: String? = nil, status: AgentStatus? = nil, statusColor: String? = nil,
         statusShape: StatusShape? = nil,
         onSelect: (() -> Void)? = nil, run: @escaping () -> Void) {
        self.id = id ?? title
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.badge = badge
        self.status = status
        self.statusColor = statusColor
        self.statusShape = statusShape
        self.onSelect = onSelect
        self.run = run
    }
}

/// Which palette is open. `actions` fuzzy-searches the app's commands; `sessions` fuzzy-searches
/// the open sessions to jump between them; `themes` fuzzy-searches the bundled themes with a live
/// preview on navigation (Enter commits, Esc reverts); `customCommands` fuzzy-searches only the
/// user-defined keymap commands (the `custom` subset of `actions`, shown without the badge).
enum PaletteMode {
    case actions
    case sessions
    case themes
    case customCommands
    case attention
}

/// Drives the command palettes: `mode` is nil when closed, else the open palette. App-global, set
/// by a toolbar/menu shortcut and observed by `ContentView` to mount the overlay.
@Observable
@MainActor
final class PaletteController {
    private(set) var mode: PaletteMode?

    /// Toggle a palette: the same shortcut again closes it; a different one switches.
    func toggle(_ mode: PaletteMode) {
        self.mode = (self.mode == mode) ? nil : mode
    }

    /// Open a specific palette unconditionally (used by the theme picker's launcher/menu item, which
    /// must open `.themes` rather than toggle it closed if it happened to already be the mode).
    func open(_ mode: PaletteMode) { self.mode = mode }

    func close() { mode = nil }
}

/// The app-target read point for the host-free metrics: `InterfaceMetrics` lives in `rookCore` and can't
/// reach `GhosttyApp`, and the three surfaces that scale together (this palette, the Ctrl-Tab switcher,
/// and the title-bar popover rows) would otherwise each carry their own copy of this lookup.
extension InterfaceMetrics {
    @MainActor static var current: InterfaceMetrics { GhosttyApp.shared.interfaceMetrics }
}

/// The palette overlay: a dimmed scrim (click to dismiss) with a top-centered search field and a
/// fuzzy-filtered result list. Type to filter, ↑/↓ to move, Enter to run, Esc to close. Mounted by
/// `ContentView` only while a palette is open; the item source switches on `controller.mode`.
struct CommandPalette: View {
    let controller: PaletteController
    let actions: AppActions
    /// Where the terminal area starts inside the window (the sidebar plus its 1pt divider, 0 when no
    /// sidebar is on screen). The panel shifts by half of it so it centers over the TERMINAL rather than
    /// the whole window; the scrim stays full width, so a click on the sidebar still dismisses.
    let terminalAreaInset: Double
    /// Caller-provided rows for a control-API pick. A non-nil array replaces the built-in mode's
    /// catalog, including when the array is empty.
    let explicitItems: [PaletteItem]?
    /// Search-field prompt for an explicit picker; nil uses the neutral picker default.
    let prompt: String?
    /// Whether an unmatched, non-empty explicit-picker query can be submitted as free text.
    let allowCustom: Bool
    let onCustom: ((String) -> Void)?
    /// Called when an explicit picker is dismissed or completes. Built-in palettes leave this nil and
    /// continue to close through `PaletteController`; a pick uses it to resolve cancellation.
    let onDismiss: (() -> Void)?

    /// The chrome text sizes and the panel's scale, read from the non-observable `GhosttyApp` — a palette
    /// mounts fresh on every open, so it can never render a stale size.
    private let metrics = InterfaceMetrics.current

    /// The panel width and results height at the 13pt default; `metrics` scales them so a larger font
    /// shows the same rows and truncates no more titles, then the window fits them.
    private static let panelWidthAtDefaultFontSize: Double = 520
    private static let resultsHeightAtDefaultFontSize: Double = 320
    /// How far down the window the panel starts.
    private static let topInsetFraction: Double = 0.12

    @State private var query: String
    @State private var selection = 0
    /// The visible, filtered result list. Held in `@State` (recomputed on query/mode change) so
    /// the rendered rows and the Enter target are guaranteed to be the same array — a recomputed
    /// property could otherwise be evaluated out of sync between the list and the run handler.
    @State private var filtered: [PaletteItem] = []
    @FocusState private var fieldFocused: Bool

    /// `initialQuery` seeds the search field for an explicit picker: the caller's `--query` opens the
    /// palette already filtered, since `.onAppear` runs the first `updateFiltered()` against it. SwiftUI
    /// selects a focused field's existing text, so the first keystroke REPLACES the seed.
    init(controller: PaletteController, actions: AppActions, terminalAreaInset: Double,
         items: [PaletteItem]? = nil, prompt: String? = nil, initialQuery: String? = nil,
         allowCustom: Bool = false, onCustom: ((String) -> Void)? = nil,
         onDismiss: (() -> Void)? = nil) {
        self.controller = controller
        self.actions = actions
        self.terminalAreaInset = terminalAreaInset
        self.explicitItems = items
        self.prompt = prompt
        _query = State(initialValue: initialQuery ?? "")
        self.allowCustom = allowCustom
        self.onCustom = onCustom
        self.onDismiss = onDismiss
    }

    private var allItems: [PaletteItem] {
        if let explicitItems { return explicitItems }
        switch controller.mode {
        case .actions: return actions.paletteActions()
        case .sessions: return actions.paletteSessions()
        case .themes: return actions.paletteThemes()
        case .customCommands: return actions.paletteCustomCommands()
        case .attention: return actions.paletteAttention()
        case .none: return []
        }
    }

    /// Recomputes `filtered` for the current query: keep items whose search keys match (`paletteSearchKeys`
    /// — label only for a caller-supplied picker, label plus subtitle for a built-in palette), best score
    /// first, then alphabetically by title (so equal-scoring matches are ordered predictably). An empty
    /// query lists a built-in palette A→Z, but leaves a caller-supplied picker and `.attention` in their
    /// source order. The query is trimmed of whitespace AND newlines first: `fuzzyScore` splits on both,
    /// so a blank query that kept a newline would score every row 0 and lose the source order to the
    /// tie-break.
    private func updateFiltered() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // skipping the rank is what preserves the source order — the attention palette's
        // paletteAttention()/attentionSessions ranking (blocked→active→completed, newest change first), and
        // a picker's caller-supplied array order. every row scores 0 for an empty query, so the tie-break
        // below would re-sort them A→Z and Return would run the alphabetically-first row instead of the
        // intended one. fuzzy filtering still applies once the user types.
        if q.isEmpty, explicitItems != nil || controller.mode == .attention {
            filtered = allItems
            selection = filtered.isEmpty ? 0 : min(selection, filtered.count - 1)
            return
        }
        filtered = fuzzyRank(query: q, items: allItems) { item in
            paletteSearchKeys(title: item.title, subtitle: item.subtitle, callerSupplied: explicitItems != nil)
        }
        if explicitItems != nil,
           let label = pickCustomRowLabel(query: q, filteredCount: filtered.count, allowCustom: allowCustom) {
            filtered = [PaletteItem(id: "pick-custom", title: label) { onCustom?(q) }]
        }
        selection = filtered.isEmpty ? 0 : min(selection, filtered.count - 1)
    }

    private var placeholder: String {
        if explicitItems != nil { return prompt ?? "Select…" }
        switch controller.mode {
        case .sessions: return "Go to session…"
        case .themes: return "Select a theme…"
        case .customCommands: return "Run a custom command…"
        case .attention: return "Go to a session that needs attention…"
        default: return "Run an action…"
        }
    }

    /// Enter/leave the live-preview theme session as the palette opens, switches mode, or closes:
    /// entering `.themes` captures the current theme (so Esc can revert) and starts the selection on
    /// the current theme's row; leaving it (to another mode or closed) reverts any uncommitted preview.
    /// Idempotent — `AppActions` guards begin/cancel on its active flag.
    private func syncThemeSession() {
        guard explicitItems == nil, controller.mode == .themes else {
            actions.cancelThemePreview()
            return
        }
        actions.beginThemePreview()
        if let index = filtered.firstIndex(where: { $0.id == actions.currentThemeID }) { selection = index }
    }

    var body: some View {
        GeometryReader { geo in
            let width = metrics.fittedPanelWidth(idealAtDefault: Self.panelWidthAtDefaultFontSize,
                                                 windowWidth: geo.size.width,
                                                 terminalAreaInset: terminalAreaInset)
            ZStack(alignment: .top) {
                Color.black.opacity(0.2)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .accessibilityElement()
                    .accessibilityIdentifier(explicitItems == nil ? "palette-scrim" : "pick-scrim")
                panel
                    .frame(width: width)
                    // `.top`, or the panel centers inside a frame taller than itself and drops down the
                    // window: the cap is a ceiling on how far it may grow, not a height to fill.
                    .frame(maxHeight: metrics.fittedPanelHeight(windowHeight: geo.size.height,
                                                                topFraction: Self.topInsetFraction),
                           alignment: .top)
                    .padding(.top, geo.size.height * Self.topInsetFraction)
                    .offset(x: metrics.panelOffset(width: width, windowWidth: geo.size.width,
                                                   terminalAreaInset: terminalAreaInset))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: metrics.base))
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .font(.system(size: metrics.base))
                    .onSubmit { runSelected() }
                    .onChange(of: query) { selection = 0; updateFiltered(); previewSelected() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(metrics.scaled(12))
            Divider()
            results
        }
        // keep the live material inside its own invalidation boundary: an arrow-key selection change
        // rebuilds the palette content, and an AnyShapeStyle backdrop passed from here is opaque to
        // SwiftUI's diffing, so the whole panel backdrop got re-resolved on every keystroke.
        .background { PalettePanelBackground() }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1)))
        .shadow(radius: 24)
        .accessibilityIdentifier(explicitItems == nil ? "command-palette" : "pick-palette")
        .onAppear {
            fieldFocused = true
            updateFiltered()
            if explicitItems == nil { syncThemeSession() }
            // a palette opened from a title-bar button (the attention bell) mounts while that button
            // still holds first responder, so the synchronous focus above loses the race and the field
            // never takes the keyboard. re-assert on the next runloop tick — after the click settles —
            // so the field wins. for the menu/hotkey/⌃P paths the field is already focused by then, so
            // this is a no-op (see swiftui focus-pattern: onAppear focus may need a main-async kick).
            DispatchQueue.main.async { fieldFocused = true }
        }
        // a pick's rows come from the caller, not from `controller.mode`: a built-in palette switching mode
        // underneath must not re-filter (or re-enter the theme preview) inside the picker.
        .onChange(of: controller.mode) {
            guard explicitItems == nil else { return }
            selection = 0
            updateFiltered()
            syncThemeSession()
        }
        .onDisappear {
            if explicitItems == nil { actions.cancelThemePreview() }
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                        PaletteRow(item: item, isSelected: index == selection, metrics: metrics)
                            .id(item.id)
                            .onTapGesture { runItem(item) }
                    }
                }
            }
            .frame(maxHeight: metrics.scaled(Self.resultsHeightAtDefaultFontSize))
            .onChange(of: selection) { _, sel in
                guard filtered.indices.contains(sel) else { return }
                // live theme preview: navigating a row applies it (no-op for non-theme palettes,
                // whose items carry no onSelect).
                filtered[sel].onSelect?()
                // anchorless scrollTo is a no-op while the row is already visible and reveals only the
                // minimum at an edge. animating a center-anchored scroll on every key-repeat event kept
                // interrupting layout/compositing, which is what made the material-backed panel flash.
                proxy.scrollTo(filtered[sel].id)
            }
        }
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selection = max(0, min(selection + delta, filtered.count - 1))
    }

    /// Preview the currently-selected item (fires its `onSelect`). Called after a filter re-orders the
    /// list so the new top match previews even when `selection` stayed 0 (no `onChange(of: selection)`).
    /// A no-op for non-theme palettes — only theme rows carry an `onSelect`.
    private func previewSelected() {
        guard filtered.indices.contains(selection) else { return }
        filtered[selection].onSelect?()
    }

    private func runSelected() {
        guard filtered.indices.contains(selection) else { return }
        runItem(filtered[selection])
    }

    private func runItem(_ item: PaletteItem) {
        item.run()
        dismiss()
    }

    /// Close the palette. A built-in one closes through `PaletteController` (which unmounts the overlay);
    /// a pick has no controller state of its own — its `onDismiss` resolves the pending pick, and the
    /// resolution is what unmounts it.
    private func dismiss() {
        if explicitItems == nil { controller.close() }
        onDismiss?()
    }
}

/// The floating-panel treatment is the native material, unless Reduce Transparency asks for a solid
/// surface — then the system window color, which keeps the system-label text legible either side of
/// light/dark. SwiftUI re-renders this on a live flip; nothing is written to settings.
/// It is a view of its OWN so a selection change in `CommandPalette` cannot invalidate and re-resolve
/// the whole backdrop.
private struct PalettePanelBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder var body: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor))
        } else {
            RoundedRectangle(cornerRadius: 12).fill(.regularMaterial)
        }
    }
}

/// A real row view gives SwiftUI a narrow diffing boundary: a selection change updates the previous and
/// the next row instead of rebuilding every row the lazy stack has on screen (which a `row(_:index:)`
/// helper reading `selection` forced).
private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool
    /// Passed IN rather than read from `GhosttyApp` here: a row is rebuilt on every selection change, and
    /// the palette that owns it already resolved the metrics once when it mounted.
    let metrics: InterfaceMetrics

    var body: some View {
        HStack {
            if let status = item.status {
                StatusGlyph(status: status, colorHex: item.statusColor, shape: item.statusShape)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: metrics.base))
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.system(size: metrics.secondary)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("palette-subtitle")
                        .accessibilityValue(subtitle)
                }
            }
            Spacer(minLength: 8)
            if let badge = item.badge {
                Text(badge)
                    .font(.system(size: metrics.secondary))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2), in: Capsule())
                    .accessibilityIdentifier("palette-badge")
                    .accessibilityValue(badge)
            }
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: metrics.shortcut))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, metrics.scaled(12))
        .padding(.vertical, metrics.scaled(6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityIdentifier("palette-item-\(item.id)")
    }
}
