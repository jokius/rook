import AppKit
import Foundation
import rookCore

/// `ControlServer`'s dashboard arm: the app-side half of the host-free `dashboard` command. Split out of
/// `ControlServer.swift` (like the session/window/appearance arms) to keep that file under the size limit.
extension ControlServer {
    /// Open or close the target window's dashboard overlay — the app side of the host-free `dashboard`
    /// command (the dispatcher validated the args and built `fontMode`; it no longer caps the ids). Resolves
    /// `window ?? frontmost` to an OPEN window's store. With `mru` it pulls up to `DashboardLayout.maxCells`
    /// of that window's most-recently-used sessions from the store's recency (fewer if it has fewer; nothing
    /// goes unresolved); otherwise it resolves each id to a session in THAT store, deduping by resolved UUID
    /// (order preserved) and reporting any that don't resolve in `result.text` (never a silent drop). It then
    /// EXPANDS each resolved session IN ORDER into pane cells — always its `.primary` pane, plus a `.split`
    /// cell when the session `hasSplit` (both shells alive) — so a split session shows as TWO cells. The
    /// `DashboardLayout.maxCells` (9) cap now counts PANES, applied here after expansion; any dropped panes
    /// are reported alongside `unresolved` (joined with "; "). Each cell reparents its OWN pane surface
    /// (`.primary` → `\.surface`, `.split` → `\.splitSurface`) app-side in `WindowContentView`. Opening closes
    /// any active terminal zoom for the window (zoom and dashboard are mutually exclusive) and drives that
    /// window's `DashboardController` via the registry; `--close` calls `close()`. The per-window controller
    /// is registered by `WindowContentView`; until it is (or while the window is tearing down) the registry
    /// returns nil and this reports the window isn't open.
    func setDashboard(targets: [String], window: String?, close: Bool,
                      fontMode: DashboardFontMode, mru: Bool) -> ControlResponse {
        resolver.resolvePlacementStore(window) { store in
            guard let windowID = library.windowID(for: store),
                  let controller = DashboardControllerRegistry.shared.controller(for: windowID) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            if close {
                controller.close()
                return ControlResponse(ok: true)
            }
            var sessionIDs: [UUID] = []
            var unresolved: [String] = []
            if mru {
                // --mru: pull the window's most-recently-used sessions (≤ maxCells) from the store's recency;
                // there are no explicit ids to resolve, so nothing goes unresolved.
                sessionIDs = store.recentSessions(limit: DashboardLayout.maxCells)
                guard !sessionIDs.isEmpty else {
                    return ControlResponse(ok: false, error: "no recent sessions")
                }
            } else {
                let candidates = store.workspaces.flatMap { $0.sessions.map(\.id) }
                var seen = Set<UUID>()
                for target in targets {
                    guard case .resolved(let id) = ControlResolve.resolve(target, candidates: candidates,
                                                                          active: store.selectedSessionID),
                          store.session(withID: id) != nil else {
                        unresolved.append(target)
                        continue
                    }
                    if seen.insert(id).inserted { sessionIDs.append(id) }
                }
                guard !sessionIDs.isEmpty else {
                    return ControlResponse(ok: false, error: "no dashboard sessions resolved")
                }
            }
            // expand each resolved session into pane cells (always the primary pane, plus the split pane when the
            // session hasSplit) and cap the resulting PANE list to the 9-cell limit — the shared host-free
            // AppStore helper, so this expansion+cap has one implementation with AppActions.toggleDashboard.
            let (members, droppedPanes) = store.dashboardMembers(for: sessionIDs, limit: DashboardLayout.maxCells)
            // zoom and dashboard are mutually exclusive: drop any active zoom for this window on open.
            TerminalZoomRegistry.shared.controller(for: windowID)?.clear()
            controller.open(members: members, fontMode: fontMode)
            // set the applied font size SYNCHRONOUSLY so the `dashboardFontSize` tree read-back is
            // authoritative at command return: the SwiftUI onChange that applies the surface overrides runs a
            // runloop turn later, and open() never resets appliedFontSize — an untouched re-open would
            // otherwise leak the prior fixed/auto size. Idempotent with the wiring, which resolves the same
            // (base, member-count, mode) through the shared DashboardFontMode.appliedFontSize seam.
            let base = settingsModel.settings.fontSize ?? DashboardLayout.ghosttyDefaultFontSize
            controller.setAppliedFontSize(fontMode.appliedFontSize(memberCount: members.count, base: base))
            // combine "unresolved: …" (ids that didn't resolve) with a dropped-panes note (panes past the
            // 9-cell cap) into one message, joined with "; " — neither clobbers the other.
            var notes: [String] = []
            if !unresolved.isEmpty { notes.append("unresolved: \(unresolved.joined(separator: ", "))") }
            if droppedPanes > 0 {
                notes.append("dropped \(droppedPanes) pane(s) beyond the \(DashboardLayout.maxCells)-cell limit")
            }
            guard !notes.isEmpty else { return ControlResponse(ok: true) }
            return ControlResponse(ok: true, result: ControlResult(text: notes.joined(separator: "; ")))
        }
    }
}
