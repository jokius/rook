import Foundation
@testable import rookCore

// The mock's workspace witnesses — see `MockControlActions`.
extension MockControlActions {
    func createWorkspace(window: String?, name: String?, collapsed: Bool) -> ControlResponse {
        calls.append(.workspaceNew(window: window, name, collapsed: collapsed))
        return ControlResponse(ok: true)
    }

    func setWorkspaceExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse {
        calls.append(.workspaceExpansion(target: target, window: window, expanded: expanded))
        return ControlResponse(ok: true)
    }

    func selectWorkspace(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.workspaceSelect(target: target, window: window))
        return ControlResponse(ok: true)
    }

    func renameWorkspace(_ target: String?, window: String?, name: String) -> ControlResponse {
        calls.append(.workspaceRename(target: target, window: window, name))
        return ControlResponse(ok: true)
    }

    func deleteWorkspace(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.workspaceDelete(target: target, window: window))
        return ControlResponse(ok: true)
    }

    func moveWorkspace(_ target: String?, window: String?, direction: ReorderDirection) -> ControlResponse {
        calls.append(.workspaceMove(target: target, window: window, direction))
        return ControlResponse(ok: true)
    }

    func focusWorkspace(_ target: String?, window: String?, mode: ControlWorkspaceFocusMode) -> ControlResponse {
        calls.append(.workspaceFocus(target: target, window: window, mode))
        guard let store else { return ControlResponse(ok: true) }
        guard let id = resolveWorkspace(target, in: store) else {
            return ControlResponse(ok: false, error: "no such workspace: \(target ?? "active")")
        }
        store.applyFocusMode(mode, to: id)
        return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
    }

    func setWorkspaceFilter(window: String?, mode: ControlToggleMode) -> ControlResponse {
        calls.append(.workspaceFilter(window: window, mode: mode))
        store?.applyWorkspaceFilter(mode)
        return ControlResponse(ok: true)
    }

    /// The app-side arm's target resolution, and nothing else — the same `ControlResolve.resolve` over the
    /// store's workspace ids that `ControlServer.resolveWorkspace` runs, so the live-store seam addresses a
    /// workspace exactly the way the real host does.
    private func resolveWorkspace(_ target: String?, in store: AppStore) -> UUID? {
        let resolution = ControlResolve.resolve(target ?? "active",
                                                candidates: store.workspaces.map(\.id),
                                                active: store.currentWorkspaceID)
        guard case .resolved(let id) = resolution else { return nil }
        return id
    }

    func setWorkspaceColor(_ target: String?, window: String?, hex: String?) -> ControlResponse {
        calls.append(.workspaceColor(target: target, window: window, hex: hex))
        return ControlResponse(ok: true)
    }

    func setWorkspaceIcon(_ target: String?, window: String?, icon: WorkspaceIcon?) -> ControlResponse {
        calls.append(.workspaceIcon(target: target, window: window, icon: icon))
        return ControlResponse(ok: true)
    }

    func setWorkspaceRoot(_ target: String?, window: String?, path: String?) -> ControlResponse {
        calls.append(.workspaceRoot(target: target, window: window, path: path))
        return ControlResponse(ok: true)
    }
}
