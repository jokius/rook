import Foundation
@testable import rookCore

// The mock's native-picker witnesses — see `MockControlActions`.
extension MockControlActions {
    func openPick(_ pick: PendingPick, window: String?, follow: Bool) -> ControlResponse {
        calls.append(.pickOpen(pick, window: window, follow: follow))
        return nextPickOpenResponse
    }

    func pickResult(_ target: String, window: String?) -> ControlResponse {
        calls.append(.pickResult(target: target, window: window))
        return nextPickResultResponse
    }

    func cancelPick(_ target: String, window: String?) -> ControlResponse {
        calls.append(.pickCancel(target: target, window: window))
        return nextPickCancelResponse
    }
}
