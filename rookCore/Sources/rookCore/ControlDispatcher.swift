import Foundation

/// App-facing operations a host must provide for commands routed through `ControlDispatcher`.
/// The dispatcher owns command parsing and response shape; the host keeps target resolution and
/// platform-specific side effects.
@MainActor
public protocol ControlActions {
    func controlTree(window: String?) -> ControlResponse
    /// Reads one page from the app-run event ring. The dispatcher owns cursor/kind/limit validation;
    /// the host only reaches the ring, which is app-wide (not per-window), so no target resolution.
    func readEvents(_ options: ControlEventReadOptions) -> ControlResponse
    func createSession(_ options: ControlSessionCreateOptions) -> ControlResponse
    func duplicateSession(_ target: String?, window: String?) -> ControlResponse
    func selectSession(_ target: String?, window: String?) -> ControlResponse
    func goSession(window: String?, direction: SessionNavigation) -> ControlResponse
    func closeSession(_ target: String?, window: String?) -> ControlResponse
    func closeSessions(_ targets: [String], window: String?) -> ControlResponse
    func renameSession(_ target: String?, window: String?, name: String) -> ControlResponse
    func revealSession(_ target: String?, window: String?) -> ControlResponse
    /// Creates a workspace in the target window. `collapsed` seeds it closed in the sidebar
    /// (`workspace.new --collapsed`) so a script can fill it with `session.new --no-select` without it opening.
    func createWorkspace(window: String?, name: String?, collapsed: Bool) -> ControlResponse
    func selectWorkspace(_ target: String?, window: String?) -> ControlResponse
    func renameWorkspace(_ target: String?, window: String?, name: String) -> ControlResponse
    func deleteWorkspace(_ target: String?, window: String?) -> ControlResponse
    func moveSession(_ target: String?, window: String?, move: ControlSessionMove) -> ControlResponse
    func moveSessions(_ targets: [String], window: String?, move: ControlSessionMove) -> ControlResponse
    func moveWorkspace(_ target: String?, window: String?, direction: ReorderDirection) -> ControlResponse
    /// Marks or unmarks ONE workspace in the target window's sidebar focus set. The mode is parsed and
    /// rejected by the dispatcher, so the host only resolves the target and applies the already-valid mode
    /// through `AppStore.applyFocusMode` — every set/flag semantic stays host-free there.
    func focusWorkspace(_ target: String?, window: String?, mode: ControlWorkspaceFocusMode) -> ControlResponse
    /// Applies (or lifts) a window's workspace focus filter WITHOUT touching which workspace is marked.
    /// Window-scoped, so it takes no workspace target — the host resolves the store from `window`
    /// (frontmost when nil). The mode is parsed by the dispatcher; the on/off/toggle semantics are
    /// host-free in `AppStore.applyWorkspaceFilter`, so this only resolves the store and calls it.
    func setWorkspaceFilter(window: String?, mode: ControlToggleMode) -> ControlResponse
    /// Sets the workspace's sidebar icon color; `hex` is a validated `#rrggbb`, or nil to reset it to the
    /// theme default. The dispatcher owns the validation — this only resolves the target and mutates.
    func setWorkspaceColor(_ target: String?, window: String?, hex: String?) -> ControlResponse
    /// Sets the workspace's sidebar icon, or clears it with nil. The dispatcher has classified the raw
    /// argument and checked what it can host-free; the app still owns the two AppKit/filesystem steps —
    /// validating an SF Symbol name (`NSImage(systemSymbolName:)`) and copying an image into the state dir.
    func setWorkspaceIcon(_ target: String?, window: String?, icon: WorkspaceIcon?) -> ControlResponse
    /// Sets the workspace's root directory, or clears it with nil. The dispatcher owns the clear-semantics
    /// (a literal `clear` or an omitted path clears); this only resolves the target, mutates, and — at
    /// spawn time, not here — falls back to home when the directory does not exist.
    func setWorkspaceRoot(_ target: String?, window: String?, path: String?) -> ControlResponse
    /// Collapses (`expanded: false`) or expands (`expanded: true`) ONE workspace in the target window's
    /// sidebar tree — the per-workspace analogue of the all-workspace `expandWorkspaces`/`collapseWorkspaces`.
    /// The host persists `Workspace.isExpanded` itself (the `collapsed` read-back's source of truth) and only
    /// then pokes the live outline, so it works with the sidebar hidden.
    func setWorkspaceExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse
    func setSessionFlag(_ target: String?, window: String?, mode: String?) -> ControlResponse
    func markSessionSeen(_ target: String?, window: String?) -> ControlResponse
    func setSessionStatus(_ target: String?, window: String?, update: ControlSessionStatusUpdate) -> ControlResponse
    /// Writes a pane's PERSISTED restore-command override (consumed on the NEXT launch, never this run).
    /// The dispatcher has parsed the tri-state and validated the command; the host resolves the target
    /// session and the live pane slot, then stores the value — it also owns the pane rejections that need a
    /// session (`scratch`, `right` without a split, an unresolvable `paneID` given without an explicit
    /// `pane`) and must refuse to acknowledge a write that did not reach disk.
    func setSessionRestore(_ target: String?, window: String?,
                           update: ControlSessionRestoreUpdate) -> ControlResponse
    /// Records (or clears, with a nil `update.ref`) the agent conversation a pane is on, so a restart can
    /// resume it. The dispatcher has validated the agent kind and the pane; the app still owns target
    /// resolution and the ownership check — `update.agentPid` must be the target pane's foreground process,
    /// or the report came from a nested agent and is dropped.
    func setAgentSession(_ target: String?, window: String?, update: ControlAgentSessionUpdate) -> ControlResponse
    func splitSession(_ target: String?, window: String?, mode: String?) -> ControlResponse
    func scratchSession(_ target: String?, window: String?, mode: String?, command: String?) -> ControlResponse
    func fileTreeSession(_ target: String?, window: String?, mode: String?, path: String?) -> ControlResponse
    /// Opens/closes/toggles the session's Markdown preview panel. The dispatcher has parsed the mode and
    /// enforced "open needs a path"; the app still owns target resolution and the filesystem check (the
    /// path must exist and not be a directory), plus resolving a relative path against the session's cwd.
    func markdownSession(_ target: String?, window: String?, mode: ControlToggleMode,
                         path: String?) -> ControlResponse
    func focusSessionPane(_ target: String?, window: String?, pane: String?) -> ControlResponse
    func resizeSplit(_ target: String?, window: String?, resize: ControlSplitResize) -> ControlResponse
    func setSurfaceZoom(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse
    func setDashboard(targets: [String], window: String?, close: Bool,
                      fontMode: DashboardFontMode, mru: Bool) -> ControlResponse
    func font(_ target: String?, window: String?, pane: String?, action: String) -> ControlResponse
    func reloadKeymap() -> ControlResponse
    /// The read side of `reloadKeymap()`: the resolved keymap projected host-free by
    /// `ControlKeymap.project`, plus the live menu-bar key equivalents only the app target can read.
    func listKeymap() -> ControlResponse
    func reloadGhosttyConfig() -> ControlResponse
    func sendNotification(_ target: String?, window: String?, title: String?, body: String) -> ControlResponse
    func setTheme(args: ControlArgs?) -> ControlResponse
    func listThemes() -> ControlResponse
    func setSidebarVisibility(_ mode: ControlToggleMode) -> ControlResponse
    func setSidebarViewMode(_ mode: ControlSidebarViewMode) -> ControlResponse
    func expandSidebar(window: String?) -> ControlResponse
    func collapseSidebar(window: String?) -> ControlResponse
    func setQuickTerminal(mode: String?) -> ControlResponse
    func typeQuick(text: String) async -> ControlResponse
    func readQuickText(all: Bool, lines: Int?) async -> ControlResponse
    func typeSession(_ target: String?, window: String?, options: ControlSessionTypeOptions) async -> ControlResponse
    /// Broadcast `session.type`: inject the same text into EVERY resolved session. `targets` is the
    /// explicit ordered batch (empty when `flagged` selects the set instead); `flagged` types into the
    /// window's flagged working set. Resolution is all-or-nothing like the batch `session.close`, but the
    /// injection itself is best-effort — `result.affected` reports how many sessions actually took the
    /// text, and a partial failure answers `ok: false` WITH that count rather than claiming success.
    func typeSessions(_ targets: [String], flagged: Bool, window: String?,
                      options: ControlSessionTypeOptions) async -> ControlResponse
    func copySessionSelection(_ target: String?, window: String?) -> ControlResponse
    func pasteSession(_ target: String?, window: String?) -> ControlResponse
    func selectAllSession(_ target: String?, window: String?) -> ControlResponse
    func searchSession(_ target: String?, window: String?,
                       text: String?, to: String?) async -> ControlResponse
    func openSessionOverlay(_ target: String?, window: String?,
                            options: ControlSessionOverlayOpenOptions) -> ControlResponse
    func closeSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse
    func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?) -> ControlResponse
    func sessionOverlayResult(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse
    func setSessionBackground(_ target: String?, window: String?,
                              options: ControlSessionBackgroundOptions) -> ControlResponse
    func readSessionText(_ target: String?, window: String?, options: ControlSessionTextOptions) -> ControlResponse
    func windowNew(name: String?, minimized: Bool) async -> ControlResponse
    func windowList() -> ControlResponse
    func windowSelect(_ target: String?) async -> ControlResponse
    func windowClose(_ target: String?) async -> ControlResponse
    func windowRename(_ target: String?, name: String) -> ControlResponse
    func windowDelete(_ target: String?) -> ControlResponse
    func windowResize(_ target: String?, width: Int, height: Int) -> ControlResponse
    func windowMove(_ target: String?, x: Int, y: Int, display: Int?) -> ControlResponse
    func windowZoom(_ target: String?) -> ControlResponse
    func windowFullscreen(_ target: String?) -> ControlResponse
    func windowMinimize(_ target: String?, mode: ControlToggleMode) async -> ControlResponse
    func clearRestoreCommands() -> ControlResponse
}

public struct ControlSessionTypeOptions: Equatable, Sendable {
    public let text: String
    public let select: Bool
    public let pane: String?

    public init(text: String, select: Bool, pane: String?) {
        self.text = text
        self.select = select
        self.pane = pane
    }
}

public struct ControlSessionOverlayOpenOptions: Equatable, Sendable {
    public let command: String
    public let cwd: String?
    public let wait: Bool
    public let sizePercent: Int?
    public let backgroundColor: String?
    public let follow: Bool
    /// The pane to cover, nil for the session-wide overlay. A pane overlay is always full, so this and
    /// `sizePercent` are mutually exclusive (rejected in the dispatcher).
    public let pane: OverlayPane?

    public init(command: String, cwd: String?, wait: Bool, sizePercent: Int?, backgroundColor: String?,
                follow: Bool = false, pane: OverlayPane? = nil) {
        self.command = command
        self.cwd = cwd
        self.wait = wait
        self.sizePercent = sizePercent
        self.backgroundColor = backgroundColor
        self.follow = follow
        self.pane = pane
    }
}

public struct ControlSessionBackgroundOptions: Equatable, Sendable {
    public let watermark: BackgroundWatermark?

    public init(watermark: BackgroundWatermark?) {
        self.watermark = watermark
    }
}

public struct ControlSessionTextOptions: Equatable, Sendable {
    public let pane: String?
    public let all: Bool
    public let lines: Int?

    public init(pane: String?, all: Bool, lines: Int?) {
        self.pane = pane
        self.all = all
        self.lines = lines
    }
}

/// Routes control commands through a host-provided action seam. The dispatcher owns command parsing and
/// response shape; host actions keep target resolution, AppKit state, and terminal-surface side effects.
@MainActor
public struct ControlDispatcher {
    let actions: any ControlActions

    public init(actions: any ControlActions) {
        self.actions = actions
    }

    public func dispatch(_ request: ControlRequest) async -> ControlResponse? {
        switch request.cmd {
        case .tree:
            return actions.controlTree(window: request.args?.window)
        case .eventsRead:
            return dispatchEventsRead(request)
        case .sessionNew, .sessionDuplicate, .sessionSelect, .sessionGo, .sessionClose, .sessionRename,
                .sessionReveal, .sessionMove, .sessionFlag, .sessionSeen, .sessionStatus, .sessionAgent,
                .sessionRestore:
            return dispatchSessionCommand(request)
        case .sessionSplit, .sessionScratch, .sessionFileTree, .sessionMarkdown, .sessionFocus, .sessionResize,
                .surfaceZoom,
                .sessionType,
                .sessionCopy, .sessionPaste, .sessionSelectAll, .sessionSearch, .sessionOverlayOpen,
                .sessionOverlayClose, .sessionOverlayResize, .sessionOverlayResult, .sessionBackground,
                .sessionText:
            return await dispatchSessionSurfaceCommand(request)
        case .workspaceNew, .workspaceSelect, .workspaceRename, .workspaceDelete,
                .workspaceMove, .workspaceFocus, .workspaceFilter, .workspaceColor, .workspaceIcon,
                .workspaceRoot, .workspaceCollapse, .workspaceExpand:
            return dispatchWorkspaceCommand(request)
        case .quick, .fontInc, .fontDec, .fontReset, .keymapReload, .keymapList,
                .configReload, .notify, .themeSet, .themeList, .sidebar, .sidebarMode, .sidebarExpand,
                .sidebarCollapse, .restoreClear:
            return dispatchAppCommand(request)
        case .quickType, .quickText:
            return await dispatchQuickCommand(request)
        case .windowNew, .windowList, .windowSelect, .windowClose, .windowRename,
                .windowDelete, .windowResize, .windowMove, .windowZoom, .windowFullscreen, .windowMinimize:
            return await dispatchWindowCommand(request)
        case .dashboard:
            return dispatchDashboard(request)
        case .debugAppearance:
            // UI-test-only seam handled app-side in `ControlServer` (needs AppKit + `ContentView.isUITestLaunch`).
            return nil
        }
    }

    /// Validates and normalizes an `events.read` request. `--run`/`--after` are a PAIR — one without the
    /// other is a caller bug, not a bootstrap, so it is rejected rather than silently re-anchoring the
    /// consumer at the tail (which would drop everything since its last page without saying so).
    private func dispatchEventsRead(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let cursor: ControlEventCursor?
        switch (args?.run, args?.after) {
        case (nil, nil):
            cursor = nil
        case (.some, nil), (nil, .some):
            return ControlResponse(ok: false, error: ControlEventRequestError.cursorPair)
        case let (.some(runText), .some(afterText)):
            guard let run = UUID(uuidString: runText) else {
                return ControlResponse(ok: false, error: ControlEventRequestError.invalidRun)
            }
            guard let after = UInt64(afterText) else {
                return ControlResponse(ok: false, error: ControlEventRequestError.invalidCursor)
            }
            cursor = ControlEventCursor(run: run, after: after)
        }

        let limit = args?.limit ?? 100
        guard (1...1_000).contains(limit) else {
            return ControlResponse(ok: false, error: ControlEventRequestError.invalidLimit)
        }

        var parsedKinds = Set<ControlEventKind>()
        for field in args?.kinds ?? [] {
            for component in field.split(separator: ",", omittingEmptySubsequences: false) {
                let rawKind = component.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let kind = ControlEventKind(rawValue: rawKind) else {
                    return ControlResponse(ok: false, error: ControlEventRequestError.invalidKind(rawKind))
                }
                parsedKinds.insert(kind)
            }
        }
        let kinds: Set<ControlEventKind>? = parsedKinds.isEmpty ? nil : parsedKinds
        return actions.readEvents(ControlEventReadOptions(cursor: cursor, kinds: kinds, limit: limit))
    }

    /// The outcome of parsing a `--pane` role selector: the pane (nil when the selector was absent), or the
    /// rejection response the arm returns as-is.
    enum PaneSelection {
        case pane(StatusPane?)
        case rejected(ControlResponse)
    }

    /// The shared `--pane` role selector (`session.status`, `session.restore`): nil when absent, the parsed
    /// pane when valid, and the pinned rejection when the token names no pane.
    func parsePane(_ raw: String?) -> PaneSelection {
        guard let raw else { return .pane(nil) }
        guard let parsed = StatusPane(rawValue: raw) else {
            return .rejected(ControlResponse(ok: false, error: "--pane must be left, right, or scratch"))
        }
        return .pane(parsed)
    }

    private func dispatchWorkspaceCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .workspaceNew:
            return actions.createWorkspace(window: request.args?.window, name: request.args?.name,
                                           collapsed: request.args?.collapsed ?? false)
        case .workspaceSelect:
            return actions.selectWorkspace(request.target, window: request.args?.window)
        case .workspaceRename:
            guard let name = request.args?.name?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "workspace.rename requires a name")
            }
            return actions.renameWorkspace(request.target, window: request.args?.window, name: name)
        case .workspaceDelete:
            return actions.deleteWorkspace(request.target, window: request.args?.window)
        case .workspaceMove:
            guard let to = request.args?.to else {
                return ControlResponse(ok: false, error: "workspace.move requires --to")
            }
            guard let direction = ReorderDirection(rawValue: to) else {
                return ControlResponse(ok: false, error: "workspace.move --to must be up|down|top|bottom")
            }
            return actions.moveWorkspace(request.target, window: request.args?.window, direction: direction)
        case .workspaceFocus:
            // parsed + rejected BEFORE the host runs, so an unknown mode can never half-apply; the accepted
            // list is derived from `allCases`, so it cannot go stale when a mode is added. This is the last
            // mode-bearing command that used to validate app-side — see the dispatcher-first rule.
            let raw = request.args?.mode ?? ControlWorkspaceFocusMode.toggle.rawValue
            guard let mode = ControlWorkspaceFocusMode(rawValue: raw) else {
                return ControlResponse(ok: false,
                                       error: "invalid focus mode: \(raw) (\(ControlWorkspaceFocusMode.validNamesList))")
            }
            return actions.focusWorkspace(request.target, window: request.args?.window, mode: mode)
        case .workspaceFilter:
            // window-scoped: no workspace target, only the flag. Same `on|off|toggle` vocabulary and shared
            // parser as `window.minimize`, defaulting to `toggle`; parsed here so a bad mode can never
            // half-apply host-side.
            guard let mode = ControlToggleMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false,
                                       error: "invalid workspace filter mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setWorkspaceFilter(window: request.args?.window, mode: mode)
        case .workspaceColor:
            return dispatchWorkspaceColor(request)
        case .workspaceIcon:
            return dispatchWorkspaceIcon(request)
        case .workspaceRoot:
            return dispatchWorkspaceRoot(request)
        case .workspaceCollapse:
            return actions.setWorkspaceExpansion(request.target, window: request.args?.window, expanded: false)
        case .workspaceExpand:
            return actions.setWorkspaceExpansion(request.target, window: request.args?.window, expanded: true)
        default:
            preconditionFailure("unexpected workspace command: \(request.cmd.rawValue)")
        }
    }

    /// `workspace.color <target> <#rrggbb|clear>` — the literal `clear` (and an omitted color) resets the
    /// icon to the theme default, mirroring the `clear` mode the other set/clear commands use. Any other
    /// value must be a `#rrggbb` hex, validated by the same `WatermarkConfig.isValidColorHex` the
    /// `session.status`/`session.background` colors go through, so a malformed value is rejected at the
    /// boundary rather than silently falling back to the default tint.
    private func dispatchWorkspaceColor(_ request: ControlRequest) -> ControlResponse {
        let raw = request.args?.color?.trimmedOrNil
        guard let raw, raw != "clear" else {
            return actions.setWorkspaceColor(request.target, window: request.args?.window, hex: nil)
        }
        guard WatermarkConfig.isValidColorHex(raw) else {
            return ControlResponse(ok: false, error: "invalid color (expected #rrggbb)")
        }
        return actions.setWorkspaceColor(request.target, window: request.args?.window, hex: raw)
    }

    /// `workspace.icon <target> <symbol|emoji|path|clear>` — the literal `clear` (and an omitted icon)
    /// restores the default glyph. Otherwise the raw value is CLASSIFIED (`WorkspaceIcon.kind(forRawIcon:)`):
    /// a path (it contains `/` or ends in an image extension), a single emoji, else an SF Symbol name.
    ///
    /// Only the host-free checks live here: an image must be a supported format with no control characters
    /// in its path. Whether the file EXISTS and whether a symbol name RESOLVES are app-side (filesystem +
    /// AppKit), like the `session.status --sound` name check.
    private func dispatchWorkspaceIcon(_ request: ControlRequest) -> ControlResponse {
        let raw = request.args?.icon?.trimmedOrNil
        guard let raw, raw != "clear" else {
            return actions.setWorkspaceIcon(request.target, window: request.args?.window, icon: nil)
        }
        let kind = WorkspaceIcon.kind(forRawIcon: raw)
        if kind == .image {
            guard WorkspaceIcon.isSupportedImage(raw) else {
                return ControlResponse(ok: false, error: "unsupported icon image (svg, png, or jpeg)")
            }
            guard WatermarkConfig.isValidImagePath(raw) else {
                return ControlResponse(ok: false, error: "image path must not contain control characters")
            }
        }
        return actions.setWorkspaceIcon(request.target, window: request.args?.window,
                                        icon: WorkspaceIcon(kind: kind, value: raw))
    }

    /// `workspace.root <target> <dir|clear>` — the literal `clear` (and an omitted path) clears the root,
    /// mirroring the `clear` idiom the other workspace set/clear commands use. Any other value passes
    /// through as the root directory. Whether the directory EXISTS is decided at spawn time (app-side, a
    /// fallback to home), so the dispatcher stays host-free and does no filesystem check.
    private func dispatchWorkspaceRoot(_ request: ControlRequest) -> ControlResponse {
        let raw = request.args?.path?.trimmedOrNil
        guard let raw, raw != "clear" else {
            return actions.setWorkspaceRoot(request.target, window: request.args?.window, path: nil)
        }
        return actions.setWorkspaceRoot(request.target, window: request.args?.window, path: raw)
    }

    private func dispatchAppCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .fontInc:
            return actions.font(request.target, window: request.args?.window,
                                pane: request.args?.pane, action: "increase_font_size:1")
        case .fontDec:
            return actions.font(request.target, window: request.args?.window,
                                pane: request.args?.pane, action: "decrease_font_size:1")
        case .fontReset:
            return actions.font(request.target, window: request.args?.window,
                                pane: request.args?.pane, action: "reset_font_size")
        case .quick:
            return actions.setQuickTerminal(mode: request.args?.mode)
        case .keymapReload:
            return actions.reloadKeymap()
        case .keymapList:
            return actions.listKeymap()
        case .configReload:
            return actions.reloadGhosttyConfig()
        case .notify:
            guard let body = request.args?.body, !body.isEmpty else {
                return ControlResponse(ok: false, error: "notify requires a body")
            }
            return actions.sendNotification(request.target, window: request.args?.window,
                                            title: request.args?.title, body: body)
        case .themeSet:
            return actions.setTheme(args: request.args)
        case .themeList:
            return actions.listThemes()
        case .sidebar:
            guard let mode = ControlToggleMode.parse(request.args?.mode, on: "show", off: "hide") else {
                return ControlResponse(ok: false, error: "invalid sidebar mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setSidebarVisibility(mode)
        case .sidebarMode:
            guard let mode = ControlSidebarViewMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false, error: "invalid sidebar mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setSidebarViewMode(mode)
        case .sidebarExpand:
            return actions.expandSidebar(window: request.args?.window)
        case .sidebarCollapse:
            return actions.collapseSidebar(window: request.args?.window)
        case .restoreClear:
            return actions.clearRestoreCommands()
        default:
            preconditionFailure("unexpected app command: \(request.cmd.rawValue)")
        }
    }

    /// The quick-terminal input/read commands, `async` because the app side polls briefly for the surface
    /// to mount + realize after `quick show` (the twin of `session.type`/`session.text`, which are async
    /// for the same realize-wait reason).
    private func dispatchQuickCommand(_ request: ControlRequest) async -> ControlResponse {
        switch request.cmd {
        case .quickType:
            guard let text = request.args?.text else {
                return ControlResponse(ok: false, error: "quick.type requires text")
            }
            return await actions.typeQuick(text: text)
        case .quickText:
            let all = request.args?.all ?? false
            let lines = request.args?.lines
            if all, lines != nil {
                return ControlResponse(ok: false, error: "use either --all or --lines, not both")
            }
            if let lines, lines <= 0 {
                return ControlResponse(ok: false, error: "--lines must be greater than 0")
            }
            return await actions.readQuickText(all: all, lines: lines)
        default:
            preconditionFailure("unexpected quick command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchWindowCommand(_ request: ControlRequest) async -> ControlResponse {
        switch request.cmd {
        case .windowNew:
            return await actions.windowNew(name: request.args?.name, minimized: request.args?.minimized ?? false)
        case .windowList:
            return actions.windowList()
        case .windowSelect:
            return await actions.windowSelect(request.target)
        case .windowClose:
            return await actions.windowClose(request.target)
        case .windowRename:
            guard let name = request.args?.name?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "window.rename requires a name")
            }
            return actions.windowRename(request.target, name: name)
        case .windowDelete:
            return actions.windowDelete(request.target)
        case .windowResize:
            guard let width = request.args?.width, let height = request.args?.height,
                  width > 0, height > 0 else {
                return ControlResponse(ok: false, error: "window.resize requires positive width and height")
            }
            return actions.windowResize(request.target, width: width, height: height)
        case .windowMove:
            guard let x = request.args?.x, let y = request.args?.y else {
                return ControlResponse(ok: false, error: "window.move requires x and y")
            }
            return actions.windowMove(request.target, x: x, y: y, display: request.args?.display)
        case .windowZoom:
            return actions.windowZoom(request.target)
        case .windowFullscreen:
            return actions.windowFullscreen(request.target)
        case .windowMinimize:
            guard let mode = ControlToggleMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false, error: "invalid window minimize mode: \(request.args?.mode ?? "toggle")")
            }
            return await actions.windowMinimize(request.target, mode: mode)
        default:
            preconditionFailure("unexpected window command: \(request.cmd.rawValue)")
        }
    }

    /// The dashboard overlay is host-free-validated here. The open path needs at least one id (or `--mru`)
    /// and at most one font flag; `--close` takes no id, `--mru`, or font flag; a `--font-size` must be
    /// finite and positive; `--mru` cannot be combined with explicit ids (but composes with the font flags);
    /// and every id parses as a `DashboardTarget` — a malformed pane suffix fails the WHOLE command here,
    /// while a well-formed ref naming no live pane is an app-side miss.
    /// The 9-cell cap is NOT applied here: the cell unit is a session+pane, so a split session expands to two
    /// cells and the cap counts PANES — that expansion needs the store, so it lives app-side in
    /// `ControlServer.setDashboard`, which also reports any dropped panes. Target resolution (incl. the
    /// `--mru` recency lookup), the pane expansion + cap, the surface reparent, and the per-window controller
    /// all stay app-side behind `ControlActions.setDashboard`; this forwards the ids as raw strings once
    /// their grammar is checked.
    private func dispatchDashboard(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let targets = args?.targets ?? []
        let fontSize = args?.fontSize
        let autoSize = args?.autoSize ?? false
        let mru = args?.mru ?? false

        if args?.close == true {
            guard targets.isEmpty, !mru, fontSize == nil, !autoSize else {
                return ControlResponse(ok: false, error: "dashboard --close takes no ids, --mru, or font options")
            }
            return actions.setDashboard(targets: [], window: args?.window, close: true, fontMode: .untouched, mru: false)
        }

        if fontSize != nil, autoSize {
            return ControlResponse(ok: false, error: "dashboard: --font-size is mutually exclusive with --auto-size")
        }
        if let fontSize, !fontSize.isFinite || fontSize <= 0 {
            return ControlResponse(ok: false, error: "dashboard --font-size must be a positive number")
        }
        let fontMode: DashboardFontMode = autoSize ? .auto : (fontSize.map(DashboardFontMode.fixed) ?? .untouched)
        if mru {
            // --mru supplies the members app-side from the window's recency, so it takes no explicit ids; the
            // font flags still apply.
            guard targets.isEmpty else {
                return ControlResponse(ok: false, error: "dashboard --mru cannot be combined with explicit session ids")
            }
            return actions.setDashboard(targets: [], window: args?.window, close: false, fontMode: fontMode, mru: true)
        }
        guard !targets.isEmpty else {
            return ControlResponse(ok: false, error: "dashboard requires at least one session id")
        }
        // GRAMMAR only: a malformed pane suffix (or an empty target) fails the command here, while a
        // well-formed ref that resolves to nothing is app-side and joins the `unresolved` note instead.
        if let malformed = targets.first(where: { DashboardTarget(rawValue: $0) == nil }) {
            return ControlResponse(
                ok: false,
                error: "dashboard: invalid session id '\(malformed)' — use <id>, <id>:left, or <id>:right")
        }
        return actions.setDashboard(targets: targets, window: args?.window, close: false, fontMode: fontMode, mru: false)
    }
}
