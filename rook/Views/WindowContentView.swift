import rookCore
import AppKit
import Combine
import SwiftUI

/// Window-local handoff between picker dismissal and the owning window becoming frontmost.
/// A background window must not claim first responder, but its removed picker field cannot remain
/// the responder when that window is activated later.
struct PickFocusRestorationState {
    private(set) var isDeferred = false

    mutating func pickerResolved(isFrontmost: Bool) -> Bool {
        isDeferred = !isFrontmost
        return isFrontmost
    }

    mutating func windowBecameFrontmost(pickPending: Bool) -> Bool {
        guard isDeferred, !pickPending else { return false }
        isDeferred = false
        return true
    }
}

/// The actual per-window UI: the workspace/session sidebar + the active session's terminal, plus
/// the quick-terminal / palette / switcher overlays. Holds the resolved non-optional `AppStore` so
/// the binding-based wiring is unchanged from the single-window version; `ContentView` resolves the
/// store and hands it in.
struct WindowContentView: View {
    let windowID: WindowInfo.ID
    @Bindable var store: AppStore
    let library: WindowLibrary
    let makeSurface: (Session) -> GhosttySurfaceView
    let makeSplitSurface: (Session) -> GhosttySurfaceView
    /// nil builds the session-wide overlay surface, `left`/`right` the pane-scoped one reading that pane's slot.
    let makeOverlaySurface: (Session, OverlayPane?) -> GhosttySurfaceView
    let makeScratchSurface: (Session) -> GhosttySurfaceView
    /// The quick terminal's spawn environment for this window; the second argument is the shell it was
    /// asked to run (`quick --shell`), which the builder exports as `SHELL`.
    let quickTerminalEnv: (WindowInfo.ID, String?) -> [String: String]
    let actions: AppActions
    let palette: PaletteController
    let sessionSwitcher: SessionSwitcher
    /// This window's own quick terminal, owned here (one per window). Registered in
    /// `QuickTerminalRegistry` on appear so the frontmost-window call sites can reach it, and its
    /// `cwdProvider` binds to this window's active session.
    @State var quickTerminal = QuickTerminalController()
    /// Window-level terminal zoom: rehosts the currently visible terminal surface above the sidebar,
    /// titlebar, quick terminal frame, palettes, and switcher until the toggle is invoked again.
    @State var terminalZoom = TerminalZoomController()
    /// Window-level dashboard grid overlay: reparents a control-picked set of member session surfaces into a
    /// view-only grid. Registered in `DashboardControllerRegistry` on appear so the socket can drive it; the
    /// `+Dashboard` extension owns the overlay branch, deck yield, font override, and modal lifecycle.
    @State var dashboard = DashboardController()
    /// Per-window native picker presented through the shared palette view. Registered for control-socket
    /// lookup while this window is mounted; unlike `palette`, its pending state is window-scoped.
    @State var pick = PickController()
    /// Tracks this view's balanced auto-follow suppression so window teardown can release it even when
    /// SwiftUI removes the observer before the pick controller publishes its cancellation.
    @State private var pickSuppressesAutoFollow = false
    /// Defers picker focus restoration when a control request resolves in a background window. The
    /// always-mounted frontmost observer consumes it without activating or ordering that window.
    @State private var pickFocusRestoration = PickFocusRestorationState()
    /// The terminal background color, mirrored from the (non-observable) `GhosttyApp` into view
    /// state and used as the quick terminal's opaque backing, so a settings theme change (posting
    /// `.rookAppearanceChanged`) re-renders it live.
    @State var terminalColor: Color = WindowContentView.resolvedTerminalColor()
    /// Mirror of `GhosttyApp.toolbarMode`: `normal` shows the cwd subtitle, `compact` collapses the title
    /// bar to a single line, `hidden` drops the row (and the traffic lights) for a full-bleed terminal.
    /// Refreshed on `.rookAppearanceChanged`, like `terminalColor`.
    @State var toolbarMode: ToolbarMode = WindowContentView.resolvedToolbarMode()
    /// Mirror of `GhosttyApp.inactivePaneMuteStrength` (0...10): how strongly the mute wash fades the text
    /// of a terminal that does not hold focus. Refreshed on `.rookAppearanceChanged`, like `toolbarMode`.
    @State private var inactivePaneMute: Int = WindowContentView.resolvedInactivePaneMute()
    /// Mirror of `GhosttyApp.windowOpacity`: the window's saved background opacity, which scales the mute
    /// wash — see `muteWashOpacity`. Refreshed on `.rookAppearanceChanged`, like `inactivePaneMute`.
    @State private var windowOpacity: Double = WindowContentView.resolvedWindowOpacity()
    /// Whether THIS window is in native fullscreen, where AppKit renders it opaque whatever the saved
    /// opacity says. Per-window state, so it rides the fullscreen notifications instead of the app-global
    /// `GhosttyApp` mirrors.
    @State private var windowFullscreen = false
    /// `WindowAppearance.sync`'s OTHER opaque-forcing condition; SwiftUI keeps it current by itself.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Live pointer/drag state for `sidebarDivider`'s grab handle, read by its deferred cursor re-assert.
    @State private var dividerHovered = false
    @State private var dividerDragging = false
    /// Mirror of `GhosttyApp.sidebarBackgroundShift` (0...10, 5 = neutral): how much lighter/darker the
    /// sidebar background is than the terminal. Drives `sidebarTintWash`; refreshed on
    /// `.rookAppearanceChanged`, like `inactivePaneMute`.
    @State var sidebarShift: Int = WindowContentView.resolvedSidebarShift()
    /// The terminal theme's foreground color, mirrored from `GhosttyApp` and used for the chrome text
    /// (title bar text + buttons, sidebar bottom bar) so non-terminal text tracks the theme. Refreshed
    /// on `.rookAppearanceChanged`, like `terminalColor`.
    @State var chromeText: Color = WindowContentView.resolvedChromeText()
    /// Mirror of `GhosttyApp.attentionButtonEnabled`: when true the title bar shows the attention bell.
    /// Refreshed on `.rookAppearanceChanged`, like `toolbarMode`, so flipping the Settings toggle
    /// shows/hides the bell live without a relaunch.
    @State var attentionButtonEnabled: Bool = WindowContentView.resolvedAttentionButtonEnabled()
    /// Mirror of `GhosttyApp.hiddenInterfaceElements`: the title-bar / sidebar-footer chrome elements the
    /// user has hidden in Settings ▸ Interface. Refreshed on `.rookAppearanceChanged`, like `toolbarMode`,
    /// so flipping a toggle shows/hides the element live without a relaunch. `shows(_:)` reads it.
    @State var hiddenInterfaceElements: Set<InterfaceElement> = WindowContentView.resolvedHiddenInterfaceElements()
    /// Whether the recent-sessions popover (the mouse form of the Ctrl-Tab switcher) is shown, anchored on
    /// the title-bar clock button. Internal so the `+RecentSessions` extension's button/rows can toggle it.
    @State var recentSessionsShown = false
    /// Whether the attention popover (the mouse form of the ⌃⇧I attention palette) is shown, anchored on the
    /// title-bar bell. Internal so the `+RecentSessions` extension's bell/rows can toggle it.
    @State var attentionPopoverShown = false
    /// Custom sidebar width and show/hide both live on the per-window `AppStore` (`sidebarWidth` /
    /// `sidebarVisible`), persisted in `Snapshot` so they restore on relaunch. The toolbar button, the View
    /// menu, the palette, and the `sidebar` control command share `sidebarVisible`.
    /// Height of the custom titlebar row: two lines (title + cwd) when normal, one short line when
    /// compact, and zero when hidden (the row collapses to an invisible drag strip and the terminal
    /// runs full-bleed). The split content is inset by this so it sits below the row.
    var titlebarHeight: CGFloat {
        switch toolbarMode {
        case .normal: return 48
        case .compact: return 30
        case .hidden: return 0
        }
    }

    /// Both native-fullscreen edges as ONE publisher: this body sits near the type checker's limit, so an
    /// extra `onReceive` in the chain costs real compile time. The handler re-reads the live style mask,
    /// so one closure serves both edges.
    private var fullscreenEdges: AnyPublisher<Notification, Never> {
        let center = NotificationCenter.default
        return center.publisher(for: NSWindow.didEnterFullScreenNotification)
            .merge(with: center.publisher(for: NSWindow.didExitFullScreenNotification))
            .eraseToAnyPublisher()
    }

    var body: some View {
        ZStack(alignment: .top) {
            windowBody
            // A control picker is the window's topmost modal — LAST in this outer stack, so it stays visible
            // and interactive even when terminal zoom or the dashboard was already active when the request
            // arrived. Its own stack level rather than another child of the inner one: that ZStack already
            // sits at the type checker's limit, and wrapping keeps every existing zIndex untouched.
            pickModalLayer
        }
        // with the title bar hidden (.hiddenTitleBar), pull our header to the very top so the traffic
        // lights overlay it as one row; no system title bar is left to clip the content.
        .ignoresSafeArea(.container, edges: .top)
        // re-tint the sidebar after a collapse/expand: the re-attached NSScrollView comes back with a
        // default (lighter) background until the next WindowAppearance sync; nudge that sync now.
        .onChange(of: store.sidebarVisible) { _, visible in
            if visible {
                DispatchQueue.main.async { NotificationCenter.default.post(name: .rookAppearanceChanged, object: nil) }
            } else {
                // hiding mid-drag (⌘⌃S, the palette, `sidebar hide`) removes the divider and cancels its
                // gesture with no `onEnded`, so these would stay latched: ↔ would survive the next hover exit
                // and the arrow would never be restored.
                dividerHovered = false
                dividerDragging = false
            }
        }
        // when the quick terminal hides, return focus to the active session's terminal — unless THIS
        // window's zoom owns focus (zoom-enter hides the quick terminal itself, and `actions` targets
        // the FRONTMOST window, so a background window's zoom-driven hide must not move focus there).
        .onChange(of: quickTerminal.isVisible) { _, visible in
            if !visible, terminalZoom.target == .quick { terminalZoom.clear() }
            if !visible, terminalZoom.target == nil { actions.focusActiveSession() }
        }
        .onChange(of: terminalZoom.target) { old, new in
            handleZoomTargetChange(old: old, new: new)
            // reciprocal exclusivity: a zoom becoming active while the dashboard is open closes the dashboard.
            closeDashboardIfZoomActive(new)
        }
        // dashboard open/close drives the modal lifecycle + auto-follow pause; the font key (members + font
        // mode) drives the per-member transient font override, so a retarget OR a same-members re-open with a
        // new font mode re-sizes; the session-id set drives member reconcile (prune a closed member).
        .onChange(of: dashboard.isOpen) { _, isOpen in
            handleDashboardOpenChange(isOpen)
        }
        .onChange(of: dashboardFontKey) { _, _ in
            handleDashboardFontChange()
        }
        .onChange(of: dashboardValidMembers) { _, _ in
            reconcileDashboardMembers()
        }
        // Editor-overlay reload hooks must stay mounted while terminal zoom replaces the normal deck.
        .onChange(of: openOverlaySessionIDs) { old, new in
            handleClosedEditorOverlays(previousOpenOverlaySessionIDs: old, currentOpenOverlaySessionIDs: new)
        }
        // a palette is a transient overlay that owns the keyboard: suppress this window's auto-follow while
        // it is open so an armed idle jump can't reshuffle the selection under it (an action-palette run
        // would then hit the wrong session), and resume + return focus to the terminal when it closes.
        .onChange(of: palette.mode == nil) { _, closed in
            if closed {
                store.resumeAutoFollow()
                actions.focusActiveSession()
            } else {
                store.suppressAutoFollow()
            }
        }
        .onChange(of: pendingPickID) { (old: String?, new: String?) in
            handlePickPendingChange(old: old, new: new)
        }
        // a settings appearance change isn't observable through GhosttyApp, so re-render on the
        // notification to pick up the new terminal color in the quick terminal backing.
        .onReceive(NotificationCenter.default.publisher(for: .rookAppearanceChanged)) { _ in
            terminalColor = WindowContentView.resolvedTerminalColor()
            toolbarMode = WindowContentView.resolvedToolbarMode()
            chromeText = WindowContentView.resolvedChromeText()
            attentionButtonEnabled = WindowContentView.resolvedAttentionButtonEnabled()
            hiddenInterfaceElements = WindowContentView.resolvedHiddenInterfaceElements()
            inactivePaneMute = WindowContentView.resolvedInactivePaneMute()
            windowOpacity = WindowContentView.resolvedWindowOpacity()
            sidebarShift = WindowContentView.resolvedSidebarShift()
        }
        // this window's native-fullscreen edges: AppKit renders a fullscreen window OPAQUE whatever the
        // saved opacity says, so `muteWashOpacity` must stop scaling itself down while it is up. Re-read
        // our OWN flag rather than filtering the notification's window — another window's edge then just
        // re-reads an unchanged value.
        .onReceive(fullscreenEdges) { _ in
            let fullscreen = WindowRegistry.shared.windowFlags(for: windowID)?.fullscreen ?? false
            if fullscreen != windowFullscreen { windowFullscreen = fullscreen }
        }
        // blend the title bar with the terminal; report frontmost/close to the library; surface the
        // window un-minimized on launch. the title token makes updateNSView re-run the blend on a
        // session switch.
        .background(WindowAccessor(titleToken: windowTitle, windowID: windowID, library: library, store: store))
        // own a per-window quick terminal: register it so the frontmost-window call sites resolve it,
        // and spawn its shell in THIS window's active session's directory.
        .onAppear { wireWindowControllers() }
        .onDisappear {
            QuickTerminalRegistry.shared.unregister(windowID)
            TerminalZoomRegistry.shared.unregister(windowID)
            tearDownDashboard()
            if pickSuppressesAutoFollow {
                store.resumeAutoFollow()
                pickSuppressesAutoFollow = false
            }
            PickRegistry.shared.unregister(windowID)
        }
    }

    /// The window's own layers: the eager deck plus either the zoom cover or the overlay/titlebar chrome.
    /// Split off `body` so the outer stack can put the control picker above all of it without adding a
    /// child to this ZStack, which is at the type checker's limit.
    private var windowBody: some View {
        ZStack(alignment: .top) {
            // The split's AppKit HSplitView can overrun into the titlebar zone and steal header clicks, so
            // the deck stays inset below the titlebar. While zoomed, keep that eager deck mounted so
            // background sessions and control-opened overlays still realize their terminal surfaces and run;
            // the zoom layer owns the visible window.
            alwaysMountedSplitLayer
            if let zoomTarget = terminalZoom.target {
                terminalZoomLayer(zoomTarget)
                    .zIndex(10)
                zoomTitlebar
                    .zIndex(11)
            } else {
                // the window overlays (quick terminal / palettes / switcher) sit BELOW the titlebar, inset by
                // its height — NOT as a body-level `.overlay` above EVERYTHING. A full-window overlay's dim
                // scrim composites OVER the transparent custom titlebar (whose AppKit backing is deliberately
                // hidden for translucency, WindowAppearance), darkening + seaming the normal non-compact titlebar
                // (the corruption). Keeping the titlebar at the highest zIndex means a scrim can never cover it.
                windowOverlayLayer
                    .padding(.top, titlebarHeight)
                    .zIndex(1)
                if dashboard.isOpen {
                    // the open dashboard is a view-only modal, like terminal zoom: swap the full titlebar for
                    // a stripped bar (mirroring zoomTitlebar) so its interactive buttons can't steal the
                    // key-catcher's first responder — which strands Esc — or drive actions that make no sense
                    // behind the grid. The two modes are mutually exclusive, so only one titlebar is ever up.
                    dashboardTitlebar
                        .zIndex(2)
                } else {
                    customTitlebar
                        .zIndex(2)
                }
            }
        }
    }

    /// Own this window's per-window controllers on mount: register each in its shared registry and wire
    /// the closures they need from the view (cwd/env providers, activity, the picker focus gate). A method
    /// rather than an inline `.onAppear` closure — `body`'s modifier chain is at the type checker's limit.
    private func wireWindowControllers() {
        quickTerminal.cwdProvider = { [store] in
            store.activeSession?.effectiveCwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        }
        // the quick terminal's shell sees this window's ROOK_* env (scratch: ENABLED + WINDOW_ID + SOCKET).
        quickTerminal.envProvider = { [quickTerminalEnv, windowID] shell in quickTerminalEnv(windowID, shell) }
        // typing in the quick terminal counts as activity, so an idle auto-follow fire can't change this
        // window's selected session behind the overlay while the user types (mirrors the overlay/scratch).
        quickTerminal.onUserInput = { [store] in store.noteUserActivity() }
        quickTerminal.focusAllowed = { [pick] () -> Bool in pick.pending == nil }
        QuickTerminalRegistry.shared.register(windowID, controller: quickTerminal)
        terminalZoom.targetResolver = { [store, quickTerminal] in
            TerminalZoomController.resolveTarget(store: store, quickTerminalVisible: quickTerminal.isVisible)
        }
        TerminalZoomRegistry.shared.register(windowID, controller: terminalZoom)
        registerDashboard()
        PickRegistry.shared.register(windowID, controller: pick)
    }

    /// The pending picker's id, hoisted out of the `body` modifier chain: that chain sits at the type
    /// checker's limit, and an inline optional-chained key path there tips it over.
    private var pendingPickID: String? { pick.pending?.id }

    /// A native picker owns keyboard focus just like a built-in palette: pair auto-follow suppression per
    /// window, and return first responder to this window's terminal after every resolution path.
    private func handlePickPendingChange(old: String?, new: String?) {
        if old == nil, new != nil, !pickSuppressesAutoFollow {
            // A socket-driven picker may arrive while either title-bar popover is already open.
            // Dismiss both immediately so no second interactive surface remains above the modal picker.
            recentSessionsShown = false
            attentionPopoverShown = false
            store.suppressAutoFollow()
            pickSuppressesAutoFollow = true
        } else if old != nil, new == nil, pickSuppressesAutoFollow {
            store.resumeAutoFollow()
            pickSuppressesAutoFollow = false
            if pickFocusRestoration.pickerResolved(isFrontmost: isFrontmost) {
                restoreFocusAfterPick()
            }
        }
    }

    /// The control picker, inset by the titlebar exactly like `windowOverlayLayer` so its scrim still
    /// never composites over the transparent title bar (the transparent-titlebar-scrim rule) even though
    /// it draws above every layer of `windowBody`.
    private var pickModalLayer: some View {
        pickPaletteOverlay
            .padding(.top, titlebarHeight)
    }

    /// The eager split/deck remains mounted behind every modal presentation, including terminal zoom.
    /// Keep frontmost-driven cleanup here rather than on `windowOverlayLayer`, which is absent while
    /// zoomed: otherwise a palette owned by the old front window can survive the handoff and remount
    /// after the picker and zoom both close.
    private var alwaysMountedSplitLayer: some View {
        splitRoot
            .padding(.top, titlebarHeight)
            .opacity(terminalZoom.target == nil ? 1 : 0)
            .allowsHitTesting(terminalZoom.target == nil)
            .onChange(of: isFrontmost) { _, frontmost in
                if frontmost, pick.pending != nil { palette.close() }
                if frontmost, pickFocusRestoration.windowBecameFrontmost(pickPending: pick.pending != nil) {
                    restoreFocusAfterPick()
                }
            }
    }

    private var openOverlaySessionIDs: [UUID] {
        store.workspaces.flatMap(\.sessions).compactMap { session in
            session.overlayActive ? session.id : nil
        }
    }

    private func handleClosedEditorOverlays(previousOpenOverlaySessionIDs old: [UUID],
                                            currentOpenOverlaySessionIDs new: [UUID]) {
        let closed = Set(old).subtracting(new)
        if let id = actions.keymapEditOverlaySession, closed.contains(id) {
            // a keymap-edit overlay just closed -> reapply the edited keymap.
            actions.keymapEditOverlaySession = nil
            actions.reloadKeymap()
        }
        if let id = actions.ghosttyEditOverlaySession, closed.contains(id) {
            // a ghostty.conf-edit overlay just closed -> reload the edited ghostty config (skipped when the
            // file is unchanged, so a no-op editor session keeps per-session font zoom).
            actions.ghosttyEditOverlaySession = nil
            actions.reloadGhosttyConfigIfEdited()
        }
    }

    /// EXPERIMENT (custom-sidebar branch): our own split instead of `NavigationSplitView`, so macOS 26
    /// doesn't impose the Liquid-Glass sidebar chrome (inset panel, toggle capsule) or couple it to the
    /// toolbar style. A plain `HStack` gives the sidebar tree + a themed draggable divider + the terminal.
    @ViewBuilder private var splitRoot: some View {
        // GeometryReader wraps the split so the RIGHT-anchored file-tree divider can resolve its panel
        // width from the absolute cursor X: the panel hugs the window's right edge, so its width is
        // `totalWidth - cursor.x` — the inverse of the left-anchored sidebar's `width = cursor.x`.
        GeometryReader { geo in
            HStack(spacing: 0) {
                if store.sidebarVisible {
                    sidebarColumn
                        .frame(width: CGFloat(store.sidebarWidth))
                    sidebarDivider
                        // draw/hit above the terminal: the divider is the middle HStack child, so without this
                        // the detail column (drawn last) shadows the right half of the grab handle, leaving only
                        // a few points grabbable. zIndex lifts the whole handle on top so the full strip works.
                        .zIndex(1)
                }
                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // the per-session file-tree panel, on the RIGHT of the terminal. Shown only for the active
                // session and only when it has toggled the panel on. Like the sidebar, its show/hide is an
                // INSTANT HStack child add/remove — NEVER animate its width (the same eager-deck reason below).
                // Unlike the sidebar (per-window), its gate is `activeSession`, which flips INSIDE the
                // `withAnimation` transactions of session close / undo-close / delete-workspace — so the column
                // insert/remove must opt OUT of that ambient animation, else it interpolates the detail column's
                // width (and reflows every ghostty surface) per frame for the transaction's duration.
                if let session = store.activeSession, session.fileTreeVisible {
                    // when the preview panel is also open it sits to the RIGHT of the tree, so the tree's
                    // divider is no longer dragging against the window edge: hand it a totalWidth shortened
                    // by the preview's column, or `totalWidth - cursor.x` would overshoot by exactly that.
                    fileTreeDivider(totalWidth: geo.size.width - markdownColumnWidth)
                        .zIndex(1)
                        .transaction { $0.animation = nil }
                    fileTreeColumn(for: session)
                        .frame(width: CGFloat(store.fileTreeWidth))
                        .transaction { $0.animation = nil }
                }
                // the per-session Markdown preview panel, rightmost. Same eager-deck rule as the file tree:
                // its insert/remove must opt OUT of the ambient animation (see above).
                if let session = store.activeSession, let path = session.markdownPath {
                    markdownDivider(totalWidth: geo.size.width)
                        .zIndex(1)
                        .transaction { $0.animation = nil }
                    markdownColumn(for: session, path: path)
                        .frame(width: CGFloat(store.markdownWidth))
                        .transaction { $0.animation = nil }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // deliberately NOT animated on visibility: animating the split width interpolates the detail
            // column's frame every display frame, and detailPane is the EAGER deck (a ZStack over EVERY
            // session's surface, all mounted). so an animated collapse/expand resizes every ghostty surface
            // each frame — each resize reflows the grid (set_size) AND force-repaints (refresh), even hidden
            // opacity-0 panes — a cost that scales with total session count and janks on a window with many
            // sessions. an instant toggle reflows each surface exactly once. DO NOT re-add the width animation.
            // the mode switch below is safe to animate — it swaps sidebar CONTENT, not the split width, so
            // the detail column (and the deck) never resize.
            .animation(.easeInOut(duration: 0.15), value: store.sidebarMode)
            // the undo toast, bottom-centered over the WHOLE content (not confined to the sidebar, which can
            // be hidden). Rides splitRoot, so it inherits the zoom hide/hit-testing gate above — no toast over
            // a zoomed window; a dashboard-open window shows none either, but because close is gated while it
            // is open (no soft-close → no pending summary), not via this opacity gate.
            .overlay(alignment: .bottom) { pendingCloseToastLayer }
            .animation(.easeInOut(duration: 0.2), value: store.pendingCloseSummary?.id)
        }
    }

    /// The undo toast overlay: shown at the bottom-center after a grace-period close when the "Show undo
    /// toast" setting is on (default). Bottom-centered over the full content rather than the sidebar (which
    /// may be hidden); `.id(summary.id)` remounts it per close so its countdown restarts and the transition
    /// re-runs. See [[PendingCloseToast]] for the theming + hover-pause behavior.
    @ViewBuilder private var pendingCloseToastLayer: some View {
        if actions.settingsModel?.settings.showUndoToast ?? true, let summary = store.pendingCloseSummary {
            PendingCloseToast(
                summary: summary,
                terminalColor: terminalColor,
                chromeText: chromeText,
                onReopen: {
                    let restored = withAnimation(.easeInOut(duration: 0.16)) {
                        store.undoPendingClose(summary.id)
                    }
                    if restored { actions.focusActiveSession() }
                },
                onPause: { store.pausePendingCloseFinalization(summary.id) },
                onResume: { store.resumePendingCloseFinalization(summary.id) }
            )
            .id(summary.id)
            .padding(.bottom, 26)
            .padding(.horizontal, 8)
        }
    }

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            // matches the detail pane's hairline so the line continues across the full width under
            // the title bar (the vertical divider hangs from it at the sidebar/terminal junction).
            // themed (chromeText at low opacity), same as the detail-pane half, so it stays visible on
            // light themes too.
            Rectangle()
                .fill(chromeText.opacity(0.1))
                .frame(height: 1)
            WorkspaceSidebar(store: store, actions: actions)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        // the lighter/darker sidebar tint: a wash behind the transparent outline + bottom bar, so the
        // whole column reads as one surface a touch darker/lighter than the terminal. Behind the column
        // content (so it never tints row text) and over the window background (so it composes with
        // translucency/blur). Neutral paints nothing.
        .background(sidebarTintWash)
    }

    /// The sidebar lighter/darker wash for the current `sidebarShift`: black (darker) or white (lighter)
    /// at the shift's magnitude, composited over the window background. Compositing this over the window
    /// background equals blending the terminal color toward black/white, and works the same over an
    /// opaque or a translucent+blurred backdrop. Neutral (`amount == 0`) renders nothing.
    @ViewBuilder var sidebarTintWash: some View {
        let amount = AppSettings.sidebarShiftAmount(strength: sidebarShift)
        if amount != 0 {
            Color(white: amount > 0 ? 0 : 1).opacity(abs(amount))
        }
    }

    /// A 1px themed vertical separator with a wider invisible drag handle to resize the sidebar. The
    /// handle is wider than the line and the divider carries `.zIndex(1)` at the call site so the full
    /// grab strip is reachable from both sides (the terminal column would otherwise shadow its right half).
    private var sidebarDivider: some View {
        Rectangle()
            .fill(chromeText.opacity(0.1))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    // per MOVE, not just on entry: the handle overhangs the terminal, whose surface re-asserts
                    // its own shape on every move, and one set on entry cannot hold against a per-move writer.
                    .onContinuousHover { phase in
                        switch phase {
                        case .active:
                            dividerHovered = true
                            setDividerCursor()
                        case .ended:
                            dividerHovered = false
                            // a drag past the width clamp leaves the handle under the pointer; the drag's own
                            // re-assert owns the cursor until release.
                            if !dividerDragging { NSCursor.arrow.set() }
                        }
                    }
                    .gesture(
                        // drive width from the absolute cursor X (window coords), NOT accumulated
                        // translation: the divider moves with the width, so translation-based resize
                        // feeds back on itself and the line flickers. Absolute position is stable.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                dividerDragging = true
                                store.sidebarWidth = min(AppStore.sidebarWidthMax, max(AppStore.sidebarWidthMin, Double(value.location.x)))
                                // past the clamp the divider stops following the pointer and ends up over live
                                // terminal, with no hover event left to repaint ↔.
                                setDividerCursor()
                            }
                            // persist the new width once, on release, not on every drag tick.
                            .onEnded { _ in
                                dividerDragging = false
                                if !dividerHovered { NSCursor.arrow.set() }
                                store.save()
                            }
                    )
            }
    }

    /// Paint ↔ for the sidebar handle, then once more on the next runloop turn: a cursor replacement still
    /// lands after this synchronous `.set()` returns — SwiftUI hosts the terminal surfaces and resets the
    /// cursor as the mouse moves (see `GhosttySurfaceView.cursorUpdate`) — so a single set loses the race.
    /// The deferred pass re-reads the hover/drag state rather than capturing it, so a re-assert arriving after
    /// the pointer left cannot strand ↔ over live terminal text.
    private func setDividerCursor() {
        NSCursor.resizeLeftRight.set()
        DispatchQueue.main.async {
            guard dividerHovered || dividerDragging else { return }
            NSCursor.resizeLeftRight.set()
        }
    }

    @ViewBuilder private var detailColumn: some View {
        VStack(spacing: 0) {
            // a subtle hairline between the title bar and the terminal; lives in the
            // detail pane so it starts at the sidebar's right edge, not the full width.
            // themed (chromeText at low opacity) so it stays visible on light themes too.
            Rectangle()
                .fill(chromeText.opacity(0.1))
                .frame(height: 1)
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // the overlay renders in-deck inside `sessionDetail` (`overlayPanel`), not at this
                // `detailPane` level.
                // the search bar, anchored at the `detailPane` level (never inside `sessionDetail`'s
                // HSplitView ZStack) so toggling it can't overrun the NSSplitView up into the titlebar.
                // Sits at the top-right of the detail area, like a standard find bar.
                .overlay(alignment: .topTrailing) { searchBarLayer }
        }
    }

    /// The terminal search bar, attached as a top-aligned `.overlay` on `detailPane` — NOT inside any
    /// session's `sessionDetail`/HSplitView ZStack, so toggling it never perturbs the split and overruns the
    /// NSSplitView into the titlebar. Shown only while zoom is off and the active session's `searchActive`
    /// is set; the needle binding drives the query through `actions.updateSearchNeedle`.
    @ViewBuilder private var searchBarLayer: some View {
        if terminalZoom.target == nil, let session = store.activeSession, session.searchActive {
            TerminalSearchBar(
                needle: Binding(
                    get: { session.searchNeedle },
                    // updateSearchNeedle is the single writer of the active session's searchNeedle.
                    set: { actions.updateSearchNeedle($0) }
                ),
                displayText: session.searchDisplayText,
                onNext: { actions.navigateSearch(.next) },
                onPrevious: { actions.navigateSearch(.previous) },
                onClose: { actions.endSearch() },
                chromeText: chromeText,
                terminalColor: terminalColor
            )
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
    }

    /// Identity for a host of the PRIMARY surface slot. Stable through lazy surface creation and ordinary
    /// updates, but changes when one live surface replaces another (split-survivor promotion), so SwiftUI
    /// remounts the host instead of keeping the torn-down pane: `TerminalView.updateNSView` cannot replace
    /// the AppKit view `makeNSView` returned, and with the split HIDDEN the surrounding branch doesn't change
    /// either, so session identity alone leaves the dead primary on screen and the live survivor unhosted.
    func primarySurfaceID(_ session: Session) -> String {
        "\(session.id.uuidString)-primary-\(session.primarySurfaceHostRevision)"
    }

    /// Opacity of the mute wash, shared by the inactive split pane and the backdrop behind a floating panel
    /// (a sized overlay, the quick terminal). 0 = the user turned muting off.
    ///
    /// Scaled by the opacity the window actually RENDERS at, because the wash color is opaque while a
    /// translucent backing is not: painting alpha `m` over backing alpha `p` leaves the body at
    /// `m + p(1-m)` against a title bar still at `p`. Nothing removes that difference — coverage only adds
    /// — so the scale shrinks it in step with the window's own transparency and is a no-op at full opacity.
    /// Internal, not private: the quick terminal's tap-catcher (`+Overlays`) paints the same wash.
    var muteWashOpacity: Double {
        AppSettings.muteOpacity(strength: inactivePaneMute) * effectiveWindowOpacity
    }

    /// The saved opacity, except where `WindowAppearance.sync` forces the window opaque WITHOUT touching
    /// that setting (native fullscreen, Reduce Transparency). There the body and the title bar share one
    /// opaque backing, so the wash needs no scaling — and scaling it would under-mute, down to nothing at
    /// a saved opacity of 0 while Settings still reads 5.
    private var effectiveWindowOpacity: Double {
        windowFullscreen || reduceTransparency ? 1 : windowOpacity
    }

    /// The wash color for a session: its own solid background when it set one, else the theme background.
    /// The wash must blend background→background to fade text ALONE, so a session running on a different
    /// background needs that color or the wash tints it.
    ///
    /// Sampled at redraw, and neither source is observed: `backgroundWatermark` is `@ObservationIgnored`
    /// and a live OSC 11 color lives on the surface view. Every path that PUTS a wash on screen re-reads it
    /// (overlay, quick-terminal and split-focus state are all observed), so only a background set while a
    /// wash is already painted holds the old color, until the next observed change.
    func washColor(for session: Session) -> Color {
        guard let watermark = session.backgroundWatermark, watermark.kind == .color,
              let color = NSColor(rookHex: watermark.colorHex) else { return terminalColor }
        return Color(nsColor: color)
    }

    /// The terminal background color from the ghostty config (a dark fallback if libghostty hasn't
    /// reported one), used as the quick terminal's opaque backing. Read into the `terminalColor`
    /// view state so it re-renders when the theme changes.
    private static func resolvedTerminalColor() -> Color {
        Color(nsColor: GhosttyApp.shared.terminalBackgroundColor
            ?? NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1))
    }

    /// The toolbar mode from the (non-observable) `GhosttyApp`, mirrored into view state so a settings
    /// change (posting `.rookAppearanceChanged`) re-renders the title bar (subtitle / hidden) live.
    private static func resolvedToolbarMode() -> ToolbarMode {
        GhosttyApp.shared.toolbarMode
    }

    /// The attention-button flag from the (non-observable) `GhosttyApp`, mirrored into view state so a
    /// settings change (posting `.rookAppearanceChanged`) shows/hides the title bar bell live.
    private static func resolvedAttentionButtonEnabled() -> Bool {
        GhosttyApp.shared.attentionButtonEnabled
    }

    /// The hidden-chrome-element set from the (non-observable) `GhosttyApp`, mirrored into view state so a
    /// settings change (posting `.rookAppearanceChanged`) shows/hides the gated chrome live.
    private static func resolvedHiddenInterfaceElements() -> Set<InterfaceElement> {
        GhosttyApp.shared.hiddenInterfaceElements
    }

    /// Whether a title-bar / sidebar-footer chrome element should be drawn. Everything is shown unless the
    /// user hid it in Settings ▸ Interface.
    func shows(_ element: InterfaceElement) -> Bool {
        !hiddenInterfaceElements.contains(element)
    }

    /// The mute strength from the (non-observable) `GhosttyApp`, mirrored into view state so a settings
    /// change (posting `.rookAppearanceChanged`) re-renders every washed terminal live.
    private static func resolvedInactivePaneMute() -> Int {
        GhosttyApp.shared.inactivePaneMuteStrength
    }

    /// The window background opacity from the (non-observable) `GhosttyApp`, mirrored into view state so a
    /// translucency change (posting `.rookAppearanceChanged`) re-scales the mute wash live.
    private static func resolvedWindowOpacity() -> Double {
        GhosttyApp.shared.windowOpacity
    }

    /// The sidebar background shift from the (non-observable) `GhosttyApp`, mirrored into view state so a
    /// settings change (posting `.rookAppearanceChanged`) re-tints the sidebar wash live.
    private static func resolvedSidebarShift() -> Int {
        GhosttyApp.shared.sidebarBackgroundShift
    }

    /// The terminal theme's foreground color (a light fallback if libghostty hasn't reported one),
    /// mirrored into view state so a theme change re-tints the chrome text live.
    private static func resolvedChromeText() -> Color {
        Color(nsColor: GhosttyApp.shared.terminalForegroundColor ?? .labelColor)
    }

}
