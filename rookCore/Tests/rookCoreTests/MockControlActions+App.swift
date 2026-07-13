import Foundation
@testable import rookCore

// The mock's app witnesses — see `MockControlActions`.
extension MockControlActions {
    func controlTree(window: String?) -> ControlResponse {
        calls.append(.tree(window: window))
        return nextTreeResponse
    }

    func font(_ target: String?, window: String?, pane: String?, action: String) -> ControlResponse {
        calls.append(.font(target: target, window: window, pane: pane, action))
        return nextFontResponse
    }

    func reloadKeymap() -> ControlResponse {
        calls.append(.keymapReload)
        return nextKeymapResponse
    }

    func reloadGhosttyConfig() -> ControlResponse {
        calls.append(.configReload)
        return nextConfigResponse
    }

    func sendNotification(_ target: String?, window: String?,
                          title: String?, body: String) -> ControlResponse {
        calls.append(.notify(target: target, window: window, title: title, body: body))
        return nextNotifyResponse
    }

    func setTheme(args: ControlArgs?) -> ControlResponse {
        calls.append(.themeSet(args?.name))
        return nextThemeSetResponse
    }

    func listThemes() -> ControlResponse {
        calls.append(.themeList)
        return nextThemeListResponse
    }

    func setSidebarVisibility(_ mode: ControlToggleMode) -> ControlResponse {
        calls.append(.sidebarVisibility(mode))
        return nextSidebarVisibilityResponse
    }

    func setSidebarViewMode(_ mode: ControlSidebarViewMode) -> ControlResponse {
        calls.append(.sidebarViewMode(mode))
        return nextSidebarViewModeResponse
    }

    func expandSidebar(window: String?) -> ControlResponse {
        calls.append(.expand(window: window))
        return nextExpandResponse
    }

    func collapseSidebar(window: String?) -> ControlResponse {
        calls.append(.collapse(window: window))
        return nextCollapseResponse
    }

    func setQuickTerminal(mode: String?) -> ControlResponse {
        calls.append(.quick(mode))
        return nextQuickResponse
    }

    func typeQuick(text: String) async -> ControlResponse {
        calls.append(.quickType(text: text))
        return nextQuickTypeResponse
    }

    func readQuickText(all: Bool, lines: Int?) async -> ControlResponse {
        calls.append(.quickText(all: all, lines: lines))
        return nextQuickTextResponse
    }

    func clearRestoreCommands() -> ControlResponse {
        calls.append(.restoreClear)
        return nextRestoreClearResponse
    }
}
