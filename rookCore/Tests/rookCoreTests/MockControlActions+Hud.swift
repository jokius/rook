import Foundation
@testable import rookCore

// The mock's `session.hud.*` witnesses — see `MockControlActions`.
extension MockControlActions {
    func openHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        calls.append(.hudOpen(target: target, window: window, spec))
        return nextHudOpenResponse
    }

    func updateHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        calls.append(.hudUpdate(target: target, window: window, spec))
        return nextHudUpdateResponse
    }

    func closeHud(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.hudClose(target: target, window: window))
        return nextHudCloseResponse
    }
}
