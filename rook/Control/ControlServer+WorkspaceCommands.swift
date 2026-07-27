import Foundation
import rookCore

/// `ControlServer` workspace-command adapter arms that did not fit in `ControlServer+SessionActions.swift`
/// (which sits at the swiftlint size limit); they satisfy `ControlActions` requirements whose conformance is
/// declared there. Each does only target resolution + the store/AppKit side effect — validation and response
/// shaping live host-free in `ControlDispatcher`. (The all-workspace `sidebar.expand`/`sidebar.collapse` arms
/// stay in `+SessionActions.swift`.)
extension ControlServer {
    /// `workspace.new`: placement target is the window's frontmost store (or `args.window`'s); the name
    /// defaults to the auto-generated workspace name. `collapsed` seeds the workspace closed so a script can
    /// fill it with `session.new --no-select` without it opening.
    func createWorkspace(window: String?, name: String?, collapsed: Bool) -> ControlResponse {
        resolver.resolvePlacementStore(window) { store in
            let name = trimmed(name) ?? store.defaultWorkspaceName
            let workspace = store.addWorkspace(name: name, collapsed: collapsed)
            return ControlResponse(ok: true, result: ControlResult(id: workspace.id.uuidString))
        }
    }

    /// Collapse (`expanded: false`) or expand (`expanded: true`) a SINGLE workspace in a window's sidebar
    /// tree — the per-workspace analogue of the all-workspace `sidebar.expand`/`sidebar.collapse`. Resolves
    /// the target via `resolveWorkspace` (honoring the global `--window` selector like the other workspace
    /// commands), then persists `Workspace.isExpanded` on the store FIRST and only then pokes the live
    /// outline. The order is load-bearing: the store is the source of truth for the `collapsed` read-back,
    /// and `WorkspaceSidebar` is mounted only while the window's sidebar is VISIBLE, so a notification-only
    /// write would silently drop with the sidebar hidden. The notification is store-scoped (the Coordinator
    /// observes with `object: store`, like the expand/collapse-all pokes) so only the target window reacts.
    /// Idempotent — `setWorkspaceExpanded` is delta-guarded. Returns the workspace id; the read-back is the
    /// `tree` workspace node's `collapsed` field.
    ///
    /// There is deliberately no `AppActions` hop: unlike the all-workspace pair this has no GUI caller (a row
    /// click drives the outline directly), so the control arm is its only entry point.
    func setWorkspaceExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse {
        resolver.resolveWorkspace(target, window: window) { store, id in
            store.setWorkspaceExpanded(id, expanded: expanded)
            NotificationCenter.default.post(
                name: .rookSetWorkspaceExpanded, object: store,
                userInfo: [WorkspaceSidebar.Coordinator.workspaceIDUserInfoKey: id,
                           WorkspaceSidebar.Coordinator.expandedUserInfoKey: expanded])
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }
}
