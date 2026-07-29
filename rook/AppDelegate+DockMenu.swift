import rookCore
import AppKit

/// A retained target for ONE Dock-menu item. The Dock invokes a menu item with a **nil sender**, so an
/// item cannot be asked "which session am I" — `representedObject`/`sender` are useless here and the
/// identity has to live in this object's closure instead. AppKit does NOT retain an `NSMenuItem.target`,
/// so `AppDelegate.dockMenuActionTargets` holds the batch for the menu's life; every rebuild invalidates
/// the previous batch, so an item from a stale menu that somehow fires acts on nothing rather than on a
/// window/session that has since changed.
@MainActor
final class DockMenuActionTarget: NSObject {
    private let action: () -> Void
    private var isValid = true

    init(action: @escaping () -> Void) { self.action = action }

    func invalidate() { isValid = false }

    @objc func performDockMenuAction(_: Any?) {
        guard isValid else { return }
        action()
    }
}

/// The two "jump to a session" submenus, so the pair of titles travels as one argument.
private enum DockSessionGroup {
    case attention
    case recent

    /// The submenu's own title and the disabled placeholder row shown when it has no sessions.
    var titles: (menu: String, empty: String) {
        switch self {
        case .attention: ("Sessions Needing Attention", "No Sessions Need Attention")
        case .recent: ("Recent Sessions", "No Recent Sessions")
        }
    }
}

extension AppDelegate {
    /// The app-specific top of the Dock icon's contextual menu (right-click the Dock icon), rebuilt every
    /// time AppKit asks for it — so MRU order and attention state are current without maintaining a second
    /// observed menu model. Its point is reaching a WAITING AGENT while rook is in the background or
    /// hidden: the title-bar recent/attention popovers and ⌃Tab all require raising a window first.
    ///
    /// Everything is scoped to the window that is frontmost when the menu is BUILT: it is captured here,
    /// and every item raises it and takes frontmost SYNCHRONOUSLY before acting (see `activate`), so the
    /// frontmost-resolved `AppActions`/`AppStore` seam lands in the captured window. That is also why the
    /// gate is the plain frontmost `AppActions.uiActionsEnabled` rather than a per-window overload: the
    /// captured window IS `library.activeStore`'s window at build time and IS the frontmost one by the
    /// time the action runs, so a `uiActionsEnabled(for:)` would resolve the same controllers with one
    /// more API to keep in sync. Nil (no rook items, just AppKit's standard ones) when no window is open.
    ///
    /// Known ceiling: like the title-bar popovers, the ⌃Tab switcher and the palettes, this lists only the
    /// FRONTMOST window's sessions — a blocked agent in another open window is not reachable from here.
    /// Widening it means window-scoped submenus plus a cross-window activate; do that only if asked.
    @objc func applicationDockMenu(_: NSApplication) -> NSMenu? {
        dockMenuActionTargets.forEach { $0.invalidate() }
        dockMenuActionTargets.removeAll(keepingCapacity: true)

        guard let library, let store = library.activeStore, let windowID = library.windowID(for: store)
        else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false
        let enabled = actions?.uiActionsEnabled == true

        addDockItem("New Session", enabled: enabled && store.currentWorkspaceID != nil, to: menu) { [weak self, weak store] in
            guard let self, let store, activate(store) else { return }
            actions?.newSession()
        }

        addDockItem("Quick Terminal",
                    enabled: enabled && QuickTerminalRegistry.shared.controller(for: windowID) != nil,
                    to: menu) { [weak self, weak store] in
            guard let self, let store, activate(store) else { return }
            actions?.toggleQuickTerminal()
        }

        // the dashboard toggle is deliberately NOT gated on `uiActionsEnabled`: an OPEN dashboard makes
        // that false, and this item is the Dock's escape hatch that closes it (same reasoning as ⌘⇧D
        // staying enabled in the menu bar). Mirrors `toggleDashboard`'s own preconditions instead.
        let dashboard = DashboardControllerRegistry.shared.controller(for: windowID)
        addDockItem("Dashboard",
                    enabled: dashboard != nil && actions?.terminalZoomActive == false
                        && (dashboard?.isOpen == true || !store.dashboardMRUMembers(limit: 1).isEmpty),
                    to: menu) { [weak self, weak store] in
            guard let self, let store, activate(store) else { return }
            actions?.toggleDashboard()
        }

        menu.addItem(.separator())
        addSessionSubmenu(.attention, sessions: store.attentionSessions,
                          store: store, enabled: enabled, to: menu)
        addSessionSubmenu(.recent, sessions: recentDockSessions(in: store),
                          store: store, enabled: enabled, to: menu)
        return menu
    }

    /// The captured window's most-recently-used sessions EXCLUDING the active one (not a jump target —
    /// you're already there), scoped to the visible/filtered set and capped like the ⌃Tab switcher. The
    /// IDENTICAL set the title-bar recent-sessions popover lists (`WindowContentView+RecentSessions`), so
    /// the two mouse surfaces can't drift.
    private func recentDockSessions(in store: AppStore) -> [Session] {
        var valid = Set(store.navigableSessions.map(\.id))
        if let activeID = store.activeSession?.id { valid.remove(activeID) }
        return store.sessionRecency.top(SessionSwitcher.maxCandidates, in: valid)
            .compactMap(store.session(withID:))
    }

    /// One "jump to a session" submenu (recent / needing attention). Each row carries its session id in
    /// its own retained target — the nil-sender workaround — and an empty list still renders a disabled
    /// placeholder row so the submenu is never a dead-end blank.
    private func addSessionSubmenu(_ group: DockSessionGroup, sessions: [Session], store: AppStore,
                                   enabled: Bool, to menu: NSMenu) {
        let (title, empty) = group.titles
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        if sessions.isEmpty {
            let placeholder = NSMenuItem(title: empty, action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)
        }
        for session in sessions {
            let sessionID = session.id
            let workspace = store.workspace(forSession: sessionID)?.name ?? ""
            let rowTitle = workspace.isEmpty ? session.displayName : "\(session.displayName) — \(workspace)"
            addDockItem(rowTitle, enabled: enabled, to: submenu) { [weak self, weak store] in
                guard let self, let store else { return }
                selectDockSession(sessionID, in: store)
            }
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        parent.isEnabled = true
        menu.addItem(parent)
    }

    private func addDockItem(_ title: String, enabled: Bool, to menu: NSMenu, action: @escaping () -> Void) {
        let target = DockMenuActionTarget(action: action)
        dockMenuActionTargets.append(target)
        let item = NSMenuItem(title: title,
                              action: #selector(DockMenuActionTarget.performDockMenuAction(_:)),
                              keyEquivalent: "")
        item.target = target
        item.isEnabled = enabled
        menu.addItem(item)
    }

    /// Raise the captured window (`store`'s) and take frontmost, before a Dock item's action runs.
    ///
    /// The Dock does NOT activate (or unhide) the app before invoking an item, so the action must do it
    /// itself — and `WindowAccessor.reportFrontmost`, the only GUI writer of `frontmostWindowID`, fires on
    /// `didBecomeKey`, which AppKit does not deliver to an INACTIVE app (the same asymmetry the control
    /// channel's `takeFrontmost` exists for). So publish the change synchronously here — the same three
    /// writes `reportFrontmost` does — otherwise the frontmost-resolved `AppActions` would drive the
    /// PREVIOUSLY-active window for the rest of this invocation. False when the captured window is gone
    /// (closed while the menu was tracking — `windowID(for:)` searches OPEN windows by identity), which is
    /// the one fire-time re-validation the items need: the actions themselves
    /// (`newSession`/`toggleQuickTerminal`/`toggleDashboard`) re-check their own live preconditions.
    @discardableResult
    private func activate(_ store: AppStore) -> Bool {
        guard let library, let windowID = library.windowID(for: store) else { return false }
        NSApp.unhide(nil)
        NSApp.activate()
        WindowRegistry.shared.raise(windowID)
        guard library.frontmostWindowID != windowID else { return true }
        library.frontmostWindowID = windowID
        library.saveIndex()
        // let the control server refresh its cached window list so a `window.list` poll sees the new
        // `active` flag — nothing else fires for a Dock-driven frontmost change.
        NotificationCenter.default.post(name: .rookWindowFrontmostChanged, object: nil)
        return true
    }

    /// Jump to a session captured when the menu was built: select it in its (now frontmost) window and
    /// reveal the pane that raised its status. The body is the title-bar attention popover's
    /// `selectAttention` verbatim, including its routing: `selectSession` clears an `--auto-reset`
    /// indicator on the way in ("visit: you've seen it"), so the reveal reads the indicator that select
    /// RETURNS rather than the live session — otherwise a `completed --auto-reset` row would read back
    /// `.idle` and drop the user on the main pane instead of the split/scratch pane that finished. That
    /// was never Dock-specific; every select-then-reveal path shares the one captured-indicator seam.
    private func selectDockSession(_ sessionID: UUID, in store: AppStore) {
        guard store.session(withID: sessionID) != nil, activate(store) else { return }
        store.noteUserActivity()
        let indicator = store.selectSession(sessionID)
        actions?.revealActiveBlockedPane(captured: indicator)
    }
}
