import Foundation
@testable import rookCore

// The mock's window witnesses — see `MockControlActions`.
extension MockControlActions {
    func windowNew(name: String?) -> ControlResponse {
        calls.append(.windowNew(name))
        return nextWindowNewResponse
    }

    func windowList() -> ControlResponse {
        calls.append(.windowList)
        return nextWindowListResponse
    }

    func windowSelect(_ target: String?) async -> ControlResponse {
        calls.append(.windowSelect(target: target))
        return nextWindowSelectResponse
    }

    func windowClose(_ target: String?) async -> ControlResponse {
        calls.append(.windowClose(target: target))
        return nextWindowCloseResponse
    }

    func windowRename(_ target: String?, name: String) -> ControlResponse {
        calls.append(.windowRename(target: target, name))
        return nextWindowRenameResponse
    }

    func windowDelete(_ target: String?) -> ControlResponse {
        calls.append(.windowDelete(target: target))
        return nextWindowDeleteResponse
    }

    func windowResize(_ target: String?, width: Int, height: Int) -> ControlResponse {
        calls.append(.windowResize(target: target, width: width, height: height))
        return nextWindowResizeResponse
    }

    func windowMove(_ target: String?, x: Int, y: Int, display: Int?) -> ControlResponse {
        calls.append(.windowMove(target: target, x: x, y: y, display: display))
        return nextWindowMoveResponse
    }

    func windowZoom(_ target: String?) -> ControlResponse {
        calls.append(.windowZoom(target: target))
        return nextWindowZoomResponse
    }

    func windowFullscreen(_ target: String?) -> ControlResponse {
        calls.append(.windowFullscreen(target: target))
        return nextWindowFullscreenResponse
    }
}
