import Foundation
@testable import rookCore

// The mock's session witnesses — see `MockControlActions`.
extension MockControlActions {
    func createSession(_ options: ControlSessionCreateOptions) -> ControlResponse {
        calls.append(.sessionNew(options))
        return nextSessionNewResponse
    }

    func selectSession(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.sessionSelect(target: target, window: window))
        return ControlResponse(ok: true)
    }

    func goSession(window: String?, direction: SessionNavigation) -> ControlResponse {
        calls.append(.sessionGo(window: window, direction))
        return ControlResponse(ok: true)
    }

    func closeSession(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.sessionClose(target: target, window: window))
        return ControlResponse(ok: true)
    }

    func closeSessions(_ targets: [String], window: String?) -> ControlResponse {
        calls.append(.sessionCloseBatch(targets: targets, window: window))
        return ControlResponse(ok: true)
    }

    func renameSession(_ target: String?, window: String?, name: String) -> ControlResponse {
        calls.append(.sessionRename(target: target, window: window, name))
        return ControlResponse(ok: true)
    }

    func revealSession(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.sessionReveal(target: target, window: window))
        return ControlResponse(ok: true)
    }

    func moveSession(_ target: String?, window: String?, move: ControlSessionMove) -> ControlResponse {
        calls.append(.sessionMove(target: target, window: window, move))
        return ControlResponse(ok: true)
    }

    func moveSessions(_ targets: [String], window: String?, move: ControlSessionMove) -> ControlResponse {
        calls.append(.sessionMoveBatch(targets: targets, window: window, move))
        return ControlResponse(ok: true)
    }

    func setSessionFlag(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        calls.append(.sessionFlag(target: target, window: window, mode))
        return ControlResponse(ok: true)
    }

    func markSessionSeen(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.markSessionSeen(target: target, window: window))
        return ControlResponse(ok: true)
    }

    func setSessionStatus(_ target: String?, window: String?,
                          update: ControlSessionStatusUpdate) -> ControlResponse {
        calls.append(.sessionStatus(target: target, window: window, update))
        return ControlResponse(ok: true)
    }

    func splitSession(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        calls.append(.sessionSplit(target: target, window: window, mode))
        return ControlResponse(ok: true)
    }

    func scratchSession(_ target: String?, window: String?, mode: String?,
                        command: String?) -> ControlResponse {
        calls.append(.sessionScratch(target: target, window: window, mode, command: command))
        return ControlResponse(ok: true)
    }

    func fileTreeSession(_ target: String?, window: String?, mode: String?, path: String?) -> ControlResponse {
        calls.append(.sessionFileTree(target: target, window: window, mode, path: path))
        return ControlResponse(ok: true)
    }

    func focusSessionPane(_ target: String?, window: String?, pane: String?) -> ControlResponse {
        calls.append(.sessionFocus(target: target, window: window, pane))
        return ControlResponse(ok: true)
    }

    func resizeSplit(_ target: String?, window: String?, resize: ControlSplitResize) -> ControlResponse {
        calls.append(.sessionResize(target: target, window: window, resize))
        return ControlResponse(ok: true)
    }

    func setSurfaceZoom(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse {
        calls.append(.surfaceZoom(target: target, window: window, mode))
        return nextSurfaceZoomResponse
    }

    func setDashboard(targets: [String], window: String?, close: Bool,
                      fontMode: DashboardFontMode, mru: Bool) -> ControlResponse {
        calls.append(.dashboard(targets: targets, window: window, close: close, fontMode: fontMode, mru: mru))
        return nextDashboardResponse
    }

    func typeSession(_ target: String?, window: String?,
                     options: ControlSessionTypeOptions) async -> ControlResponse {
        calls.append(.sessionType(target: target, window: window, options))
        return nextSessionTypeResponse
    }

    func copySessionSelection(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.sessionCopy(target: target, window: window))
        return nextSessionCopyResponse
    }

    func pasteSession(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.sessionPaste(target: target, window: window))
        return nextSessionPasteResponse
    }

    func selectAllSession(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.sessionSelectAll(target: target, window: window))
        return nextSessionSelectAllResponse
    }

    func searchSession(_ target: String?, window: String?,
                       text: String?, to: String?) async -> ControlResponse {
        calls.append(.sessionSearch(target: target, window: window, text: text, to: to))
        return nextSessionSearchResponse
    }

    func openSessionOverlay(_ target: String?, window: String?,
                            options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        calls.append(.overlayOpen(target: target, window: window, options))
        return nextOverlayOpenResponse
    }

    func closeSessionOverlay(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.overlayClose(target: target, window: window))
        return nextOverlayCloseResponse
    }

    func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?) -> ControlResponse {
        calls.append(.overlayResize(target: target, window: window, sizePercent: sizePercent))
        return nextOverlayResizeResponse
    }

    func sessionOverlayResult(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.overlayResult(target: target, window: window))
        return nextOverlayResultResponse
    }

    func setSessionBackground(_ target: String?, window: String?,
                              options: ControlSessionBackgroundOptions) -> ControlResponse {
        calls.append(.sessionBackground(target: target, window: window, options))
        return nextSessionBackgroundResponse
    }

    func readSessionText(_ target: String?, window: String?, options: ControlSessionTextOptions) -> ControlResponse {
        calls.append(.sessionText(target: target, window: window, options))
        return nextSessionTextResponse
    }

    func markdownSession(_ target: String?, window: String?, mode: ControlToggleMode,
                         path: String?) -> ControlResponse {
        calls.append(.sessionMarkdown(target: target, window: window, mode, path: path))
        return ControlResponse(ok: true)
    }
}
