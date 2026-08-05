import AppKit
import Foundation
import rookCore

/// `ControlServer`'s dashboard arm: the app-side half of the host-free `dashboard` command. Split out of
/// `ControlServer.swift` (like the session/window/appearance arms) to keep that file under the size limit.
extension ControlServer {
    /// Open or close the target window's dashboard overlay — the app side of the host-free `dashboard`
    /// command (the dispatcher validated the args, the pane grammar, and built `fontMode`; it no longer caps
    /// the ids). Resolves `window ?? frontmost` to an OPEN window's store. With `mru` it pulls up to
    /// `DashboardLayout.maxCells` of that window's most-recently-used sessions from the store's recency (fewer
    /// if it has fewer; nothing goes unresolved); otherwise each id parses as a `DashboardTarget` and its head
    /// resolves to a session in THAT store, any that don't resolve reported in `result.text` (never a silent
    /// drop). A BARE id then EXPANDS in order into pane cells — always its `.primary` pane, plus a `.split`
    /// cell when the session `hasSplit` (both shells alive) — so a split session shows as TWO cells, while a
    /// `:left`/`:right` suffix takes that cell alone; a `:right` naming no live pane is a MISS, not an error.
    /// Cells dedup by session+pane, NOT by session, so `A:left A:right` is two cells and `A A:left` is still
    /// two. The `DashboardLayout.maxCells` (9) cap now counts PANES, applied here after expansion; any dropped
    /// panes are reported alongside `unresolved` (joined with "; "). Emptiness is judged on the expanded
    /// CELLS, since a resolved id can now contribute none. Each cell reparents its OWN pane surface
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
            var resolvedTargets: [ResolvedDashboardTarget] = []
            var unresolved: [String] = []
            if mru {
                // --mru: pull the window's most-recently-used sessions (≤ maxCells) from the store's recency;
                // there are no explicit ids to resolve, so nothing goes unresolved.
                let recent = store.recentSessions(limit: DashboardLayout.maxCells)
                guard !recent.isEmpty else {
                    return ControlResponse(ok: false, error: "no recent sessions")
                }
                resolvedTargets = recent.map { ResolvedDashboardTarget(session: $0, pane: nil) }
            } else {
                let candidates = store.workspaces.flatMap { $0.sessions.map(\.id) }
                for target in targets {
                    guard let parsed = DashboardTarget(rawValue: target),
                          case .resolved(let id) = ControlResolve.resolve(parsed.head, candidates: candidates,
                                                                          active: store.selectedSessionID),
                          let session = store.session(withID: id) else {
                        unresolved.append(target)
                        continue
                    }
                    // a `:right` ref to a session with no split is a MISS, not a malformed command — the
                    // dispatcher already passed the grammar. `hasSplit` is the same test `dashboardValidMembers`
                    // reconciles against, so this never admits a cell reconcile would immediately prune.
                    guard parsed.pane != .split || session.hasSplit else {
                        unresolved.append(target)
                        continue
                    }
                    resolvedTargets.append(ResolvedDashboardTarget(session: id, pane: parsed.pane))
                }
            }
            // expand each resolved target into pane cells (a bare id: the primary pane, plus the split pane when
            // the session hasSplit; a pane ref: that cell alone) and cap the resulting PANE list to the 9-cell
            // limit — the shared host-free AppStore helper, so this expansion+cap has one implementation with
            // AppActions.toggleDashboard. It also dedups, so a bare id beside a pane ref for the same session
            // cannot double-host a surface.
            let (members, droppedPanes) = store.dashboardMembers(for: resolvedTargets,
                                                                 limit: DashboardLayout.maxCells)
            // guard the EXPANSION, not the resolved targets: with pane refs the two are no longer equivalent.
            // `dashboard <id>:right` on a session with no split resolves the id but expands to nothing, and
            // opening with an empty member set would clear the window's zoom and silently close a live
            // dashboard while reporting ok (`DashboardController.isOpen` is `!members.isEmpty`).
            guard !members.isEmpty else {
                return ControlResponse(ok: false, error: "no dashboard sessions resolved")
            }
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
