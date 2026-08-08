import Foundation
@testable import rookCore

// The mock's window witnesses — see `MockControlActions`.
extension MockControlActions {
    /// `shell` is accepted but deliberately NOT recorded on the `Call`: no test asserts it reaches the
    /// host yet, and folding it into the payload would rewrite every existing `.windowNew` expectation.
    /// Add it to the case the day a test needs it — `sessionNew` already carries it for free, inside
    /// `ControlSessionCreateOptions`.
    func windowNew(name: String?, minimized: Bool, shell: String?) async -> ControlResponse {
        calls.append(.windowNew(name, minimized: minimized))
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

    func windowMinimize(_ target: String?, mode: ControlToggleMode) async -> ControlResponse {
        calls.append(.windowMinimize(target: target, mode: mode))
        return nextWindowMinimizeResponse
    }
}
