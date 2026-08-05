import AppKit
import Foundation
import rookCore

/// `ControlServer`'s `surface.zoom` arm and its private target-resolution helpers — the active-surface
/// path, the explicit `surface:<session-id>:<kind>` / `quick` addresses, and the open-window /
/// surface-owner lookups they share. All the mode-vs-state semantics stay in the host-free
/// `TerminalZoomController`; what is here is target resolution plus the AppKit registry reads
/// (`TerminalZoomRegistry`, `QuickTerminalRegistry`). Split out of `ControlServer+SessionActions.swift`
/// to keep that file under the swiftlint size limit; the `ControlActions` conformance stays declared
/// there and an extension in any file of the module satisfies it.
extension ControlServer {
    /// Show / hide / toggle zoom for an addressable terminal surface. The default target is the active
    /// surface in the frontmost (or `--window`) window; explicit targets are `surface:<session-id>:<kind>`
    /// ids copied from `tree`.
    func setSurfaceZoom(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse {
        let rawTarget = trimmed(target) ?? "active"
        if rawTarget == "active" {
            return setActiveSurfaceZoom(window: window, mode: mode)
        }
        switch resolveSurfaceZoom(rawTarget, window: window) {
        case .failure(let response):
            return response
        case .success(let resolved):
            guard let controller = TerminalZoomRegistry.shared.controller(for: resolved.windowID) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            let want = mode.desiredValue(current: controller.target == resolved.target)
            if want, controller.target != resolved.target,
               PickRegistry.shared.controller(for: resolved.windowID)?.pending != nil {
                return ControlResponse(ok: false, error: "pick pending")
            }
            // `hide` is idempotent like the active-target arm: skip the availability check for `.off` —
            // the surface may have vanished since (an overlay exited, auto-clearing the zoom) and the
            // desired end state already holds; `set(.off, …)` on a non-matching target is a no-op.
            if mode != .off {
                guard TerminalZoomController.isTargetValid(resolved.target, in: resolved.store,
                                                           quickTerminalVisible: quickVisible(in: resolved.windowID)) else {
                    return ControlResponse(ok: false, error: "surface not available: \(resolved.controlID)")
                }
            }
            controller.set(mode, target: resolved.target)
            return ControlResponse(ok: true, result: ControlResult(id: resolved.controlID))
        }
    }

    private func setActiveSurfaceZoom(window: String?, mode: ControlToggleMode) -> ControlResponse {
        switch resolveOpenWindow(window) {
        case .failure(let response):
            return response
        case .success(let (windowID, store)):
            guard let controller = TerminalZoomRegistry.shared.controller(for: windowID) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            if controller.target == nil, mode != .off,
               PickRegistry.shared.controller(for: windowID)?.pending != nil {
                return ControlResponse(ok: false, error: "pick pending")
            }
            // this arm only picks the effective target — the current zoom when one is up (so
            // on/off/toggle act on it), else the resolved active surface — and shapes the response;
            // the mode-vs-state semantics live in the one host-free state machine,
            // `TerminalZoomController.set`, shared with the GUI toggle and the explicit-target path.
            let effectiveTarget: TerminalZoomTarget
            if let current = controller.target {
                effectiveTarget = current
            } else {
                guard mode != .off else {
                    return ControlResponse(ok: true)
                }
                let quickVisible = quickVisible(in: windowID)
                guard let zoomTarget = TerminalZoomController.resolveTarget(store: store,
                                                                            quickTerminalVisible: quickVisible) else {
                    return ControlResponse(ok: false, error: "no active surface")
                }
                guard TerminalZoomController.isTargetValid(zoomTarget, in: store, quickTerminalVisible: quickVisible) else {
                    return ControlResponse(ok: false, error: "surface not available: \(zoomTarget.controlID)")
                }
                effectiveTarget = zoomTarget
            }
            controller.set(mode, target: effectiveTarget)
            return ControlResponse(ok: true, result: ControlResult(id: effectiveTarget.controlID))
        }
    }

    private struct SurfaceZoomResolution {
        let windowID: WindowInfo.ID
        let store: AppStore
        let target: TerminalZoomTarget
        let controlID: String
    }

    private func resolveSurfaceZoom(_ target: String, window: String?)
        -> ControlTargetResolver.Resolution<SurfaceZoomResolution> {
        // `quick` is the control id this command itself returns for a quick-terminal zoom — accept it
        // back as an explicit target (the API must accept every address it emits). Validity (the quick
        // terminal actually visible) is checked by the caller's shared `isTargetValid` gate.
        if target == "quick" {
            switch resolveOpenWindow(window) {
            case .failure(let response):
                return .failure(response)
            case .success(let (windowID, store)):
                return .success(SurfaceZoomResolution(windowID: windowID, store: store,
                                                      target: .quick, controlID: "quick"))
            }
        }
        guard let surfaceID = TerminalSurfaceID(rawValue: target) else {
            return .failure(ControlResponse(ok: false, error: "invalid surface: \(target)"))
        }
        switch resolveSurfaceOwner(surfaceID, window: window) {
        case .failure(let response):
            return .failure(response)
        case .success(let (windowID, store)):
            let zoomTarget = TerminalZoomTarget.session(surfaceID.sessionID, surfaceID.surface)
            return .success(SurfaceZoomResolution(windowID: windowID, store: store,
                                                  target: zoomTarget, controlID: surfaceID.rawValue))
        }
    }

    private func resolveOpenWindow(_ window: String?) -> ControlTargetResolver.Resolution<(WindowInfo.ID, AppStore)> {
        guard let window = trimmed(window) else {
            guard let windowID = library.activeWindowID, let store = library.store(for: windowID) else {
                return .failure(ControlResponse(ok: false, error: "no open window"))
            }
            return .success((windowID, store))
        }
        switch resolver.resolveWindowID(window) {
        case .failure(let response):
            return .failure(response)
        case .success(let windowID):
            guard let store = library.store(for: windowID) else {
                return .failure(ControlResponse(ok: false, error: "window not open — window.select it first"))
            }
            return .success((windowID, store))
        }
    }

    private func resolveSurfaceOwner(_ surfaceID: TerminalSurfaceID, window: String?)
        -> ControlTargetResolver.Resolution<(WindowInfo.ID, AppStore)> {
        if trimmed(window) != nil {
            switch resolveOpenWindow(window) {
            case .failure(let response):
                return .failure(response)
            case .success(let (windowID, store)):
                guard store.session(withID: surfaceID.sessionID) != nil else {
                    return .failure(ControlResponse(ok: false, error: "no such surface: \(surfaceID.rawValue)"))
                }
                return .success((windowID, store))
            }
        }
        guard let windowID = library.windowID(forSession: surfaceID.sessionID),
              let store = library.store(for: windowID) else {
            return .failure(ControlResponse(ok: false, error: "no such surface: \(surfaceID.rawValue)"))
        }
        return .success((windowID, store))
    }

    private func quickVisible(in windowID: WindowInfo.ID) -> Bool {
        QuickTerminalRegistry.shared.controller(for: windowID)?.isVisible ?? false
    }
}
