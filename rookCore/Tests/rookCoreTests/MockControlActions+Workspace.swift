import Foundation
@testable import rookCore

// The mock's workspace witnesses — see `MockControlActions`.
extension MockControlActions {
    func createWorkspace(window: String?, name: String?) -> ControlResponse {
        calls.append(.workspaceNew(window: window, name))
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

    func focusWorkspace(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        calls.append(.workspaceFocus(target: target, window: window, mode))
        return ControlResponse(ok: true)
    }

    func setWorkspaceColor(_ target: String?, window: String?, hex: String?) -> ControlResponse {
        calls.append(.workspaceColor(target: target, window: window, hex: hex))
        return ControlResponse(ok: true)
    }

    func setWorkspaceIcon(_ target: String?, window: String?, icon: WorkspaceIcon?) -> ControlResponse {
        calls.append(.workspaceIcon(target: target, window: window, icon: icon))
        return ControlResponse(ok: true)
    }
}
