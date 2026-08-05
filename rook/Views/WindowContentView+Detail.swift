import rookCore
import AppKit
import SwiftUI

/// `WindowContentView`'s detail deck: every session's terminal content — panes, split, scratch, and the
/// overlay kinds — plus the inactive-pane mute. Split out of `WindowContentView.swift` for the file-size
/// budget; the members moved here verbatim.
extension WindowContentView {
    /// The terminal area: a DECK of EVERY session's terminal, all mounted so each is realized (its
    /// shell spawned) at startup, with only the selected one visible + hit-testable. Switching is a
    /// visibility flip, not a re-host, so the surface NSView is never detached/re-attached (re-hosting
    /// invalidates the Metal drawable and flickers). A placeholder shows behind when nothing is selected.
    @ViewBuilder var detailPane: some View {
        let sessions = store.workspaces.flatMap(\.sessions)
        ZStack {
            if store.activeSession == nil {
                Text("No session selected")
                    .foregroundStyle(.secondary)
            }
            ForEach(sessions, id: \.id) { session in
                let isActive = session.id == store.selectedSessionID
                sessionDetail(session, isActive: isActive)
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
            }
        }
    }

    /// One session's terminal content: the primary pane, a side-by-side split (`HSplitView`), or the
    /// maximized hidden-split pane, plus any overlay. `isActive` gates which pane auto-grabs focus —
    /// only the visible deck entry, and within a split only the focused pane.
    ///
    /// While terminal zoom hosts one of this session's surfaces, the deck entry stays MOUNTED with the
    /// SAME shape — only the zoom-owned slot swaps to its `deckHostsSurface` placeholder (an NSView can
    /// live in one host at a time). Everything else keeps realizing surfaces, so a control-opened
    /// split/scratch/overlay on the zoomed session still spawns and runs behind the zoom layer; swapping
    /// the whole entry out would re-host the NSSplitView (the titlebar-overrun rule) and orphan those
    /// surfaces until zoom exits. The split's arranged panes are stable ZStack wrappers (content swaps
    /// INSIDE them), so the NSSplitView never re-layouts on a zoom toggle and the divider stays put;
    /// `SplitRatioAccessor` rides the primary wrapper as one persistent instance, suspended while zoomed.
    @ViewBuilder private func sessionDetail(_ session: Session, isActive: Bool) -> some View {
        // a FULL overlay (no size) hides the session beneath it (opacity 0) and draws translucent; a
        // FLOATING overlay (overlaySizePercent set) leaves the session VISIBLE and draws a smaller
        // opaque framed panel on top. Either way the pane(s) stay non-interactive while an overlay is up.
        let fullOverlay = session.fullOverlayActive
        // While zoomed OR while the dashboard is open, the normal deck stays mounted only to realize
        // surfaces; it must not focus, register drag targets, or show focusable controls behind the
        // full-window modal layer (both are mutually exclusive, so at most one gate is ever active).
        let deckInteractive = terminalZoom.target == nil && !dashboard.isOpen
        // the scratch terminal is a full-coverage overlay too, so it hides the pane(s) exactly like a
        // FULL overlay; `hideForOverlay` drives opacity + hit-testing. `overlaid` (any overlay OR scratch)
        // is what owns focus, so it gates the pane(s)' `isActive` (focus goes to the overlay/scratch, not
        // the pane). NOTE `hideForOverlay` stays false for a FLOATING overlay — preserving the rule that
        // this subtree's shape/hit-testing must not change when a floating overlay opens (NSSplitView overrun).
        let hideForOverlay = fullOverlay || session.scratchActive
        let overlaid = session.overlayActive || session.scratchActive
        // on-screen = selected session, not hidden by a full overlay/scratch, and not covered by the
        // window-level quick terminal. Shared by BOTH split panes (unlike the focus-gated `isActive`), it
        // gates each surface's drag-type (un)registration AND its mouse-cursor tracking (the `deckVisible`
        // note in libghostty.md) so neither a file drop nor a cursor write lands on an off-screen surface.
        // `!quickTerminal.isVisible` mutes the covered pane while the quick terminal is up — otherwise the
        // covered pane keeps deckVisible=true and races the quick-terminal surface for the cursor and fans
        // mouse-motion into the covered TUI (issue #225 quick-terminal path).
        let visible = deckInteractive && isActive && !hideForOverlay && !quickTerminal.isVisible
        // computed once per entry and ANDed with each pane's own terms in `deckPane`. NOTE `focusable` here
        // is OUR pane gate — deliberately WITHOUT the `!quickTerminal.isVisible` term upstream carries, which
        // rook has never applied to the panes (only to the scratch, below); adding it would be a behavior
        // change this port does not make.
        let gates = DeckPaneGates(focusable: deckInteractive && isActive, overlaid: overlaid, visible: visible)
        ZStack {
            // the session's pane(s), kept MOUNTED while an overlay is up — shells stay alive, like the deck
            // does for inactive sessions. a FULL overlay hides them (opacity 0) so its translucency reveals the
            // window backing, not the session; a FLOATING overlay leaves them visible behind its opaque panel.
            Group {
                if session.isSplit {
                    HSplitView {
                        deckPane(session, pane: .left, focused: !session.splitFocused, gates: gates)
                            // introspects the AppKit NSSplitView to persist/restore the divider ratio, clip its
                            // divider out of the titlebar strip, paint the resize cursor, and answer the
                            // double-click even-split reset (see SplitRatioAccessor); a background on the
                            // stable pane wrapper (not a third pane, not inside the swapped content), so ONE
                            // probe instance survives zoom and its suspend/resume actually flips in place.
                            .background {
                                SplitRatioAccessor(session: session, titlebarHeight: titlebarHeight,
                                                   suspended: !deckInteractive,
                                                   deckVisible: visible && !overlaid,
                                                   onPersist: { store.save() })
                            }
                        deckPane(session, pane: .right, focused: session.splitFocused, gates: gates)
                    }
                    // per-session identity: without it SwiftUI reuses one NSSplitView across session
                    // switches and the divider (and arranged subviews) leak between sessions.
                    .id("\(session.id.uuidString)-hsplit")
                } else if session.splitFocused, session.splitSurface != nil {
                    // split hidden while the right pane had focus: show that pane maximized.
                    deckPane(session, pane: .right, focused: true, gates: gates)
                } else {
                    deckPane(session, pane: .left, focused: true, gates: gates)
                }
            }
            .opacity(hideForOverlay ? 0 : 1)
            // gate hit-testing on `hideForOverlay` (full overlay OR scratch), NOT `session.overlayActive`:
            // this modifier must NOT change when a floating overlay opens, or the AppKit NSSplitView
            // re-lays-out and overruns up into the titlebar (same class of perturbation as adding a sibling).
            // a floating overlay therefore leaves the panes hit-testable here; `overlayPanel`'s transparent
            // catcher absorbs clicks around the panel so they can't reach the panes.
            .allowsHitTesting(deckInteractive && !hideForOverlay)
            // the scratch terminal renders here, in-deck, above the (hidden) pane(s) — a full-coverage sibling
            // is safe (the panes go opacity 0, the split's frame is hidden). It sits BELOW the ephemeral overlay
            // (zIndex 1 vs `overlayPanel`'s 3) AND goes hidden while a full overlay is up, exactly like the
            // pane(s): under window translucency every surface's background renders fully transparent, so a
            // scratch left visible below would show through the overlay (reading as "the overlay opened under
            // the scratch"). BOTH overlay variants are the `overlayPanel` sibling below (zIndex 3): it is ALWAYS
            // present with a constant shape (its content is gated internally), so opening/resizing an overlay
            // never re-hosts the NSSplitView — and the floating panel's opaque backing needs no hiding of the
            // scratch behind it.
            if session.scratchActive, deckHostsSurface(session: session, surface: .scratch) {
                // gate focus on every surface that covers the scratch — a full overlay (renders above it, in
                // `overlayPanel` at zIndex 3) AND the window-level quick terminal — so the deck's focusIfNeeded can't grab the
                // scratch behind them. When the cover goes away, isActive flips true and the deck re-grabs it.
                // (matches the autoFocus suppression in makeScratchSurface.) `deckVisible` mirrors the panes'
                // rule so only an on-screen scratch is a file-drop target.
                TerminalView(session: session, surfaceKeyPath: \.scratchSurface, makeSurface: makeScratchSurface,
                             isActive: deckInteractive && isActive && !session.overlayActive && !quickTerminal.isVisible,
                             deckVisible: deckInteractive && isActive && !fullOverlay && !quickTerminal.isVisible)
                    .opacity(fullOverlay ? 0 : 1)
                    .allowsHitTesting(!fullOverlay)
                    .id("\(session.id.uuidString)-scratch")
                    .zIndex(1)
            }
            // the overlay — FULL or FLOATING — renders IN-DECK (per session) so its surface mounts + program
            // runs even when the session isn't active. ONE ALWAYS-PRESENT host (constant ZStack shape): the
            // content is gated INSIDE `overlayPanel`, the sibling itself never appears/disappears, so opening,
            // closing, OR resizing an overlay never re-hosts the NSSplitView (the titlebar-overrun trigger)
            // and never re-parents the surface (which would blank its Metal drawable). Full fills the area
            // translucent with the pane(s) hidden by `hideForOverlay`; floating draws an opaque framed panel
            // over the still-visible pane(s). Switching full<->% (session.overlay.resize) only re-flows the frame.
            overlayPanel(session: session, isActive: deckInteractive && isActive)
                .zIndex(3)
        }
        // when the overlay closes, the underlying pane must reclaim first responder. the pane re-activating
        // only does a single makeFirstResponder, which loses the race with the overlay view's teardown/
        // re-host — so drive the bounded retry the split-collapse survivor uses. gated on isActive so only
        // the visible session reclaims focus.
        // on overlay close, refocus the topmost remaining surface (scratch if still shown, else the pane)
        // via the shared `topmostSurface` precedence — never a pane hidden under the scratch, and not at all
        // while the quick terminal covers the window (it owns focus; its own hide restores the session).
        .onChange(of: session.overlayActive) { _, isOpen in
            if !isOpen, deckInteractive, isActive, !quickTerminal.isVisible {
                (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
            }
        }
        // scratch show AND hide both need the bounded focus retry: the surface is kept alive across hides,
        // so a re-show remounts it and `autoFocus`'s one-shot latch won't re-fire (same remount race as the
        // split-collapse survivor). `topmostSurface` routes focus correctly either way — on show it is the
        // scratch (or a still-open overlay above it), on hide the overlay-if-up else the pane.
        .onChange(of: session.scratchActive) { _, _ in
            // skip while the quick terminal covers the window — it owns focus above the session layers
            // (mirrors focusActiveSession); the deck re-grabs the scratch when the quick terminal hides.
            guard deckInteractive, isActive, !quickTerminal.isVisible else { return }
            (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
        }
        // the deck is the authority on which panes it lays out, so it also retires a pane overlay whose pane
        // stopped being laid out before its surface ever realized — `AppStore.toggleSplit` covers show/hide,
        // this covers every other writer of `splitFocused` (`session.focus`, a pane click, the dashboard).
        // `dropUnrealizedPaneOverlays` spares a slot terminal zoom claims, so a zoom exit is the other moment
        // the last host can disappear: re-run it there too, else un-zooming a never-mounted target strands it.
        .onChange(of: session.renderedPanes) { _, _ in session.dropUnrealizedPaneOverlays() }
        .onChange(of: terminalZoom.target) { _, _ in session.dropUnrealizedPaneOverlays() }
        // a closing pane overlay un-hides its pane and loses the same race.
        .onChange(of: session.openPaneOverlays) { before, after in
            guard after.count < before.count, deckInteractive, isActive, !quickTerminal.isVisible else { return }
            (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
        }
    }

    /// ONE pane of a session's deck entry: its terminal — or the `Color.clear` placeholder while zoom or the
    /// dashboard hosts that surface — under the always-present `paneOverlayPanel` sibling, in the
    /// constant-shape ZStack `sessionDetail` requires. This is the arranged subview of a shown split, so the
    /// `.background` probe and any per-session chrome go INSIDE here or on the result, never on a wrapper.
    ///
    /// `focused` is this pane's share of split focus: the unfocused side of a SHOWN split, else true, since a
    /// pane alone on screen always has it. It gates auto-focus for both the pane and its overlay — one
    /// opening on the other pane must not pull focus off the live one — and doubles as the `paneDim` mute,
    /// which therefore renders only on the unfocused pane of a shown split.
    @ViewBuilder private func deckPane(_ session: Session, pane: OverlayPane, focused: Bool,
                                       gates: DeckPaneGates) -> some View {
        // a pane hidden under its OWN overlay is not on screen: it registers no drag types and sets no mouse
        // cursor (the `deckVisible` note in libghostty.md, issue #225 class), and never takes first responder.
        let covered = session.paneOverlay(pane) != nil
        let slot: ReferenceWritableKeyPath<Session, (any TerminalSurface)?> =
            pane == .left ? \.surface : \.splitSurface
        ZStack {
            if deckHostsSurface(session: session, surface: pane.paneZoomSurface) {
                TerminalView(session: session, surfaceKeyPath: slot,
                             makeSurface: pane == .left ? makeSurface : makeSplitSurface,
                             isActive: gates.focusable && focused && !gates.overlaid && !covered,
                             deckVisible: gates.visible && !covered)
                    .overlay { paneDim(!focused, session: session) }
                    .modifier(PaneOverlayCover(covered: covered))
                    .id(pane == .left ? primarySurfaceID(session) : "\(session.id.uuidString)-split")
            } else {
                Color.clear
                    .id("\(session.id.uuidString)-\(pane == .left ? "primary" : "split")-placeholder")
            }
            paneOverlayPanel(session: session, pane: pane, focused: focused,
                             isActive: gates.focusable && !gates.overlaid && focused, deckVisible: gates.visible)
        }
    }

    /// ONE split pane's overlay, always FULL-PANE (no size percent, no framed chrome — a floating variant
    /// exists only at session scope). An ALWAYS-PRESENT sibling INSIDE that pane's ZStack, content gated in
    /// the GeometryReader, under the constant-shape rule `sessionDetail` states.
    ///
    /// `isActive` is the FOCUSED-pane gate (auto-focus, first responder), `deckVisible` the on-screen one
    /// (drag types, mouse cursor, clicks): an overlay on the unfocused pane stays visible and clickable —
    /// clicking it moves focus through the surface's own `onFocusChange` — without grabbing focus on open.
    /// It therefore carries `focused`'s `paneDim` too: the overlay replaces the pane the wash would have
    /// marked, so without it the unfocused side of a split reads as live.
    @ViewBuilder private func paneOverlayPanel(session: Session, pane: OverlayPane, focused: Bool,
                                               isActive: Bool, deckVisible: Bool) -> some View {
        let active = session.paneOverlay(pane) != nil
            && deckHostsSurface(session: session, surface: pane.zoomSurface)
        GeometryReader { geo in
            ZStack {
                if active {
                    // chromeless and translucent like the full session overlay: libghostty draws only the
                    // terminal, and the pane below is hidden so the window backing shows through.
                    TerminalView(session: session, surfaceKeyPath: pane.surfaceSlot,
                                 makeSurface: { makeOverlaySurface($0, pane) },
                                 isActive: isActive, deckVisible: deckVisible)
                        .overlay { paneDim(!focused, session: session, color: overlayWashColor(session, pane: pane)) }
                        .id("\(session.id.uuidString)-overlay-\(pane.rawValue)")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // inert while empty, like `overlayPanel`.
        .allowsHitTesting(deckVisible && active)
    }

    /// The overlay — FULL or FLOATING — rendered IN-DECK inside each session's `sessionDetail` ZStack as ONE
    /// ALWAYS-PRESENT sibling. The content is gated INSIDE the GeometryReader, so the ZStack's child count
    /// never changes when an overlay opens/closes (constant shape = no NSSplitView re-host = no titlebar
    /// overrun), and BOTH variants share this single surface host, so `session.overlay.resize` switching
    /// full<->% only re-flows the frame — it never re-parents the NSView (which would blank its Metal drawable).
    /// A nil `overlaySizePercent` fills the detail area translucent (no opaque backing/frame) with the pane(s)
    /// hidden by `hideForOverlay`; a percent draws an opaque, framed panel at that size, centered, with the
    /// pane(s) visible around it. Per-session in the eager deck, so the surface mounts + program runs even when
    /// the session isn't active.
    @ViewBuilder private func overlayPanel(session: Session, isActive: Bool) -> some View {
        GeometryReader { geo in
            ZStack {
                if session.overlayActive, deckHostsSurface(session: session, surface: .overlay) {
                    let floating = session.overlaySizePercent != nil
                    let fraction = session.overlaySizePercent.map { CGFloat($0) / 100 } ?? 1
                    // click-catcher over the whole detail area: absorbs clicks AROUND a floating panel so
                    // they can't reach the still-hit-testable panes and steal the overlay's first responder
                    // (the full variant hides the panes, so it's covered either way). It also CARRIES the
                    // backdrop mute — a floating panel leaves the session live behind it, so the same wash
                    // `paneDim` puts on an inactive split pane marks it inactive here. Full stays clear: its
                    // panes are already hidden, and a wash would tint the bare window backing.
                    // The fill is a VALUE on this always-present node, never a new/conditional sibling — the
                    // ZStack's shape must not change when an overlay opens (the NSSplitView-overrun rule).
                    (floating ? washColor(for: session).opacity(muteWashOpacity) : Color.clear)
                        .contentShape(Rectangle())
                    TerminalView(session: session, surfaceKeyPath: \.overlaySurface,
                                 makeSurface: { makeOverlaySurface($0, nil) },
                                 isActive: isActive, deckVisible: isActive && !quickTerminal.isVisible)
                        .frame(width: geo.size.width * fraction, height: geo.size.height * fraction)
                        // floating = opaque backing + hairline frame + shadow so it reads as a distinct window
                        // over the still-visible session; full = translucent, no chrome (libghostty draws only
                        // the terminal, so the window backing shows through). The modifier CHAIN stays constant
                        // across both variants — only the parameters go inert for full — so a full<->% resize
                        // keeps the same view tree and never re-hosts the surface NSView.
                        .background(floating ? terminalColor : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: floating ? 12 : 0))
                        .overlay(
                            RoundedRectangle(cornerRadius: floating ? 12 : 0)
                                .strokeBorder(floating ? Color.white.opacity(0.18) : Color.clear, lineWidth: 1)
                        )
                        .shadow(radius: floating ? 24 : 0)
                        .id("\(session.id.uuidString)-overlay")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // when no overlay is up the panel is an empty full-frame GeometryReader — make it inert so it never
        // intercepts clicks meant for the pane(s).
        .allowsHitTesting(isActive && session.overlayActive && deckHostsSurface(session: session, surface: .overlay))
    }

    /// Mutes the inactive split pane's TEXT so the active pane stands out, WITHOUT darkening the
    /// background: a translucent wash of the terminal background color over the pane. Background pixels
    /// blend bg→bg (unchanged), text pixels blend text→bg (less bright) — the way other terminals dim an
    /// inactive pane. Strength 0 renders nothing, and clicks pass through (`allowsHitTesting(false)`) so
    /// the muted pane can still be focused; `dimmed == false` renders nothing.
    ///
    /// Suppressed while a floating panel washes the whole backdrop, which already covers this pane — the
    /// two would stack to a stronger mute here than on the pane beside it. `color` overrides the blend
    /// target for a surface that does not render the session's background; the pane itself takes the default.
    @ViewBuilder private func paneDim(_ dimmed: Bool, session: Session, color: Color? = nil) -> some View {
        if dimmed, muteWashOpacity > 0, !backdropWashActive(session: session) {
            (color ?? washColor(for: session)).opacity(muteWashOpacity).allowsHitTesting(false)
        }
    }

    /// The blend target for a PANE OVERLAY's wash: its own `--background-color` when it set one, else the
    /// theme. An overlay surface is sessionless and never inherits the session's background — only the
    /// scratch does, through `watermarkSession` — so `washColor(for:)` would blend bg→OTHER-bg and shift
    /// the background instead of fading the text. Gated on the renderer's own hex predicate, so the wash
    /// tracks exactly what `applyOverlayBackgroundColor` painted rather than a value it rejected.
    private func overlayWashColor(_ session: Session, pane: OverlayPane) -> Color {
        guard let hex = session.paneOverlay(pane)?.backgroundColor, WatermarkConfig.isValidColorHex(hex),
              let nsColor = NSColor(rookHex: hex) else { return terminalColor }
        return Color(nsColor: nsColor)
    }

    /// Whether a floating panel is washing the whole backdrop of this session's detail pane. A FULL overlay
    /// and the scratch hide the pane(s) outright, so neither paints a backdrop.
    private func backdropWashActive(session: Session) -> Bool {
        quickTerminal.isVisible || (session.overlayActive && session.overlaySizePercent != nil)
    }
}

/// The three deck-wide gates every pane of one session's entry renders under, computed once per entry:
/// `focusable` (may take first responder at all), `overlaid` (a session-wide cover is up), and `visible`
/// (this entry is the on-screen one). `deckPane` ANDs its own pane terms into them.
private struct DeckPaneGates {
    let focusable: Bool
    let overlaid: Bool
    let visible: Bool
}

/// Hides ONE pane beneath its own full-pane overlay: that overlay is chromeless, so under window
/// translucency the pane below would show through it, and a hit-testable pane under it would steal the
/// overlay's first responder. Scoped to the covered pane alone — the sibling stays visible and interactive.
/// Applied INSIDE the arranged subview like `paneDim`, never on a wrapper.
private struct PaneOverlayCover: ViewModifier {
    let covered: Bool

    func body(content: Content) -> some View {
        content
            .opacity(covered ? 0 : 1)
            .allowsHitTesting(!covered)
    }
}
