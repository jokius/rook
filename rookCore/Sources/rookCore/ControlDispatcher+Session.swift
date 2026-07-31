import Foundation

/// `ControlDispatcher`'s session-family dispatch arms — every `session.*` command's argument parsing,
/// validation, and response shaping, including the surface/IO half (`session.type`, `session.background`,
/// `session.text`).
/// Split out of `ControlDispatcher.swift` to keep that file under the swiftlint size limit.
/// `dispatch(_:)` — the routing switch — deliberately stays in the main file, so the whole command
/// catalog is still readable in one place.
extension ControlDispatcher {
    func dispatchSessionCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionNew:
            let args = request.args
            if args?.after != nil, args?.before != nil {
                return ControlResponse(ok: false, error: "use either --after or --before, not both")
            }
            // The anchor sid carries its own workspace, so placement can't also name one.
            if args?.after != nil || args?.before != nil, args?.workspace != nil || args?.workspaceName != nil {
                return ControlResponse(ok: false, error: "session.new takes --after/--before or a workspace, not both")
            }
            if args?.workspace != nil, args?.workspaceName != nil {
                return ControlResponse(ok: false, error: "use either --workspace or --workspace-name, not both")
            }
            if args?.createWorkspace == true, args?.workspaceName == nil {
                return ControlResponse(ok: false, error: "--create-workspace requires --workspace-name")
            }
            // --wait holds the surface after the command exits, so it is meaningless without a command.
            if args?.wait == true, args?.command == nil {
                return ControlResponse(ok: false, error: "--wait requires --command")
            }
            return actions.createSession(ControlSessionCreateOptions(
                window: args?.window,
                cwd: args?.cwd,
                workspace: args?.workspace,
                workspaceName: args?.workspaceName,
                createWorkspace: args?.createWorkspace,
                command: args?.command,
                wait: args?.wait,
                name: args?.name,
                after: args?.after,
                before: args?.before,
                noSelect: args?.noSelect == true
            ))
        case .sessionDuplicate:
            // no options: the source session names its own workspace AND its cwd, so a duplicate is fully
            // described by the target. The GUI half is the sidebar row's "Duplicate".
            return actions.duplicateSession(request.target, window: request.args?.window)
        case .sessionSelect:
            return actions.selectSession(request.target, window: request.args?.window)
        case .sessionGo:
            // unknown/missing `to` is a structured error.
            guard let dir = (request.args?.to).flatMap(SessionNavigation.init(wire:)) else {
                return ControlResponse(ok: false, error: "session.go requires --to next|prev|first|last|next-attention|prev-attention")
            }
            return actions.goSession(window: request.args?.window, direction: dir)
        case .sessionClose:
            if let targets = request.args?.targets {
                guard !targets.isEmpty else {
                    return ControlResponse(ok: false, error: "session.close requires at least one --target")
                }
                return actions.closeSessions(targets, window: request.args?.window)
            }
            return actions.closeSession(request.target, window: request.args?.window)
        case .sessionRename:
            guard let name = request.args?.name else {
                return ControlResponse(ok: false, error: "session.rename requires a name")
            }
            return actions.renameSession(request.target, window: request.args?.window, name: name)
        case .sessionReveal:
            return actions.revealSession(request.target, window: request.args?.window)
        case .sessionMove:
            let args = request.args
            if args?.after != nil, args?.before != nil {
                return ControlResponse(ok: false, error: "use either --after or --before, not both")
            }
            // Placement mode: the anchor sid self-identifies the destination workspace, so it's
            // mutually exclusive with --to and with a workspace parameter.
            if let anchor = args?.after ?? args?.before {
                if args?.to != nil {
                    return ControlResponse(ok: false, error: "session.move takes --after/--before or --to, not both")
                }
                if args?.workspace != nil {
                    return ControlResponse(ok: false, error: "session.move takes --after/--before or a workspace, not both")
                }
                let move = ControlSessionMove.place(anchor: anchor, after: args?.after != nil)
                if let targets = args?.targets {
                    return dispatchSessionMove(targets: targets, window: args?.window, move: move)
                }
                return actions.moveSession(request.target, window: args?.window, move: move)
            }
            if args?.to != nil && args?.workspace != nil {
                return ControlResponse(ok: false, error: "session.move takes either --to or a workspace, not both")
            }
            if let to = args?.to {
                guard let direction = ReorderDirection(rawValue: to) else {
                    return ControlResponse(ok: false, error: "session.move --to must be up|down|top|bottom")
                }
                if args?.targets != nil {
                    return ControlResponse(ok: false, error: "session.move --target can be repeated only with a workspace or --after/--before")
                }
                return actions.moveSession(request.target, window: args?.window, move: .reorder(direction))
            }
            guard let workspace = args?.workspace else {
                return ControlResponse(ok: false, error: "session.move requires --to or a workspace")
            }
            let move = ControlSessionMove.workspace(workspace)
            if let targets = args?.targets {
                return dispatchSessionMove(targets: targets, window: args?.window, move: move)
            }
            return actions.moveSession(request.target, window: args?.window, move: move)
        case .sessionFlag:
            return actions.setSessionFlag(request.target, window: request.args?.window, mode: request.args?.mode)
        case .sessionSeen:
            return actions.markSessionSeen(request.target, window: request.args?.window)
        case .sessionStatus:
            return dispatchSessionStatus(request)
        case .sessionAgent:
            return dispatchSessionAgent(request)
        case .sessionRestore:
            return dispatchSessionRestore(request)
        default:
            preconditionFailure("unexpected session command: \(request.cmd.rawValue)")
        }
    }

    /// `session.restore`: parse the `set`|`none`|`clear` mode into a `ControlRestoreOverride` and the pane
    /// selector into a `StatusPane`, then hand both to the host. A pinned command is validated but NEVER
    /// rewritten — it is a shell line, so metacharacters are the point (that is the whole reason a pipeline
    /// or a compound `&&` restores through a pin and not through the argv capture); it is rejected only for
    /// being absent, carrying control characters, or exceeding the storage cap. An EMPTY command is the same
    /// pinned-to-nothing state as `none`. `paneID` rides through opaquely — the dispatcher has no session to
    /// resolve it against.
    func dispatchSessionRestore(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let pin: ControlRestoreOverride
        switch args?.mode ?? "" {
        case "set":
            guard let command = args?.command else {
                return ControlResponse(ok: false, error: "session.restore set requires a command")
            }
            // a control character would smuggle an extra line (or an escape sequence) into the shell the
            // override is typed into, so the whole class is rejected — tab included.
            guard !command.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
                return ControlResponse(ok: false, error: "command must not contain control characters")
            }
            guard command.utf8.count <= ControlRestoreOverride.maxCommandBytes else {
                return ControlResponse(ok: false,
                                       error: "command too long (max \(ControlRestoreOverride.maxCommandBytes) bytes)")
            }
            pin = .pin(command)
        case "none":
            pin = .pinNone
        case "clear":
            pin = .unpin
        default:
            return ControlResponse(ok: false, error: "invalid restore mode: \(args?.mode ?? "") (set|none|clear)")
        }
        let pane: StatusPane?
        switch parsePane(args?.pane) {
        case .pane(let parsed): pane = parsed
        case .rejected(let rejection): return rejection
        }
        let update = ControlSessionRestoreUpdate(pin: pin, pane: pane, paneID: args?.paneID)
        return actions.setSessionRestore(request.target, window: args?.window, update: update)
    }

    /// `session.status`: flag a per-session agent state on the sidebar row. EVERY argument is validated
    /// here, BEFORE `setSessionStatus` runs, so a typo in any one of them leaves the session's current
    /// status untouched rather than half-applying the call: the state itself, the `#rrggbb` tint, the
    /// silhouette (the shape axis, for when the tint can't carry the state), and the pane role. The
    /// opaque `--pane-id` token rides through unchecked — only the app side can resolve it against the
    /// session's live surfaces, and so does `--agent-pid`, the reporter's ownership proof (there is no
    /// pid to validate against here, and it is not user input). Its own arm (like `session.agent`'s) so
    /// the `dispatchSessionCommand` switch stays a flat router.
    func dispatchSessionStatus(_ request: ControlRequest) -> ControlResponse {
        guard let status = AgentStatus(rawValue: request.args?.status ?? "") else {
            return ControlResponse(ok: false, error: "invalid status")
        }
        if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
            return ControlResponse(ok: false, error: "invalid color (expected #rrggbb)")
        }
        var shape: StatusShape?
        if let raw = request.args?.shape {
            guard let parsed = StatusShape(rawValue: raw) else {
                return ControlResponse(ok: false, error: "invalid shape: \(raw) (\(StatusShape.validNamesList))")
            }
            shape = parsed
        }
        let pane: StatusPane?
        switch parsePane(request.args?.pane) {
        case .pane(let parsed): pane = parsed
        case .rejected(let rejection): return rejection
        }
        let update = ControlSessionStatusUpdate(status: status, blink: request.args?.blink,
                                                autoReset: request.args?.autoReset,
                                                sound: request.args?.sound, color: request.args?.color,
                                                shape: shape,
                                                pane: pane, paneID: request.args?.paneID,
                                                agentPid: request.args?.agentPid)
        return actions.setSessionStatus(request.target, window: request.args?.window, update: update)
    }

    /// `session.agent`: remember (or clear) which agent conversation a pane is on. The agent's own hook is
    /// the caller — it is the only party that knows the id — so the arguments mirror what a hook can see:
    /// the agent kind, the id from its stdin payload, its config root from the environment, its pane from
    /// `ROOK_PANE`, and its pid (the ownership proof the app checks against the pane's foreground process).
    func dispatchSessionAgent(_ request: ControlRequest) -> ControlResponse {
        guard let kind = AgentKind(rawValue: request.args?.agent ?? "") else {
            return ControlResponse(ok: false, error: "invalid agent (expected claude or codex)")
        }
        var pane: StatusPane?
        if let rawPane = request.args?.pane {
            guard let parsed = StatusPane(rawValue: rawPane) else {
                return ControlResponse(ok: false, error: "--pane must be left, right, or scratch")
            }
            // a scratch terminal is never restored (it has no persisted state), so there is no conversation
            // to resume for it — reporting one would silently do nothing
            guard parsed != .scratch else {
                return ControlResponse(ok: false, error: "session.agent supports --pane left or right")
            }
            pane = parsed
        }
        let id = request.args?.agentID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = (id?.isEmpty == false) ? AgentSessionRef(kind: kind, id: id!,
                                                           configDir: request.args?.configDir) : nil
        let update = ControlAgentSessionUpdate(ref: ref, pane: pane, agentPid: request.args?.agentPid)
        return actions.setAgentSession(request.target, window: request.args?.window, update: update)
    }

    func dispatchSessionMove(targets: [String], window: String?, move: ControlSessionMove) -> ControlResponse {
        guard let first = targets.first else {
            return ControlResponse(ok: false, error: "session.move requires at least one --target")
        }
        if targets.count == 1 {
            return actions.moveSession(first, window: window, move: move)
        }
        return actions.moveSessions(targets, window: window, move: move)
    }

    func dispatchSessionSurfaceCommand(_ request: ControlRequest) async -> ControlResponse {
        switch request.cmd {
        case .sessionSplit:
            return actions.splitSession(request.target, window: request.args?.window, mode: request.args?.mode)
        case .sessionScratch:
            return actions.scratchSession(request.target, window: request.args?.window, mode: request.args?.mode,
                                          command: request.args?.command)
        case .sessionFileTree:
            return actions.fileTreeSession(request.target, window: request.args?.window, mode: request.args?.mode,
                                           path: request.args?.path)
        case .sessionMarkdown:
            // `open` needs a file to show; `close` needs none; `toggle` closes an open panel when given no
            // path (the menu/keybind form). The FS check is app-side — the dispatcher stays host-free.
            guard let mode = ControlToggleMode.parse(request.args?.mode, on: "open", off: "close") else {
                return ControlResponse(ok: false, error: "invalid markdown mode: \(request.args?.mode ?? "toggle")")
            }
            let path = request.args?.path?.trimmedOrNil
            if mode == .on, path == nil {
                return ControlResponse(ok: false, error: "session.markdown open requires a path")
            }
            return actions.markdownSession(request.target, window: request.args?.window, mode: mode, path: path)
        case .sessionFocus:
            return actions.focusSessionPane(request.target, window: request.args?.window, pane: request.args?.pane)
        case .sessionResize:
            switch (request.args?.ratio, request.args?.ratioDelta) {
            case (nil, nil):
                return ControlResponse(ok: false, error: "session.resize requires --split-ratio, --grow-left, or --grow-right")
            case (.some, .some):
                return ControlResponse(ok: false, error: "session.resize: --split-ratio is mutually exclusive with --grow-left/--grow-right")
            case (.some(let ratio), nil):
                return actions.resizeSplit(request.target, window: request.args?.window, resize: .ratio(ratio))
            case (nil, .some(let delta)):
                return actions.resizeSplit(request.target, window: request.args?.window, resize: .delta(delta))
            }
        case .surfaceZoom:
            guard let mode = ControlToggleMode.parse(request.args?.mode, on: "show", off: "hide") else {
                return ControlResponse(ok: false, error: "invalid surface zoom mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setSurfaceZoom(request.target, window: request.args?.window, mode: mode)
        case .sessionType:
            return await dispatchSessionType(request)
        case .sessionCopy:
            return actions.copySessionSelection(request.target, window: request.args?.window)
        case .sessionPaste:
            return actions.pasteSession(request.target, window: request.args?.window)
        case .sessionSelectAll:
            return actions.selectAllSession(request.target, window: request.args?.window)
        case .sessionSearch:
            return await actions.searchSession(request.target, window: request.args?.window,
                                               text: request.args?.text, to: request.args?.to)
        case .sessionOverlayOpen:
            guard let command = request.args?.command, !command.isEmpty else {
                return ControlResponse(ok: false, error: "session.overlay.open requires a command")
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            return actions.openSessionOverlay(request.target, window: request.args?.window,
                                              options: ControlSessionOverlayOpenOptions(
                                                command: command,
                                                cwd: request.args?.cwd,
                                                wait: request.args?.wait ?? false,
                                                sizePercent: request.args?.sizePercent,
                                                backgroundColor: request.args?.color,
                                                follow: request.args?.follow ?? false
                                              ))
        case .sessionOverlayClose:
            return actions.closeSessionOverlay(request.target, window: request.args?.window)
        case .sessionOverlayResize:
            let wantsFull = request.args?.full == true
            let percent = request.args?.sizePercent
            if wantsFull, percent != nil {
                return ControlResponse(ok: false, error: "session.overlay.resize: --full is mutually exclusive with --size-percent")
            }
            if !wantsFull, percent == nil {
                return ControlResponse(ok: false, error: "session.overlay.resize requires --size-percent or --full")
            }
            if let percent, !(1...100).contains(percent) {
                return ControlResponse(ok: false, error: "session.overlay.resize: --size-percent must be 1...100")
            }
            return actions.resizeSessionOverlay(request.target, window: request.args?.window,
                                                sizePercent: wantsFull ? nil : percent)
        case .sessionOverlayResult:
            return actions.sessionOverlayResult(request.target, window: request.args?.window)
        case .sessionBackground:
            return dispatchSessionBackground(request)
        case .sessionText:
            return dispatchSessionText(request)
        default:
            preconditionFailure("unexpected session surface command: \(request.cmd.rawValue)")
        }
    }

    /// `session.type`: one target, or a BROADCAST into many. The single/absent-target form is left
    /// untouched — every script already in the wild depends on it byte-for-byte — so a broadcast is opted
    /// into only by a repeated `--target` (`args.targets`, more than one) or by `--flagged`.
    ///
    /// The two selectors are mutually exclusive: a request naming both is REJECTED rather than dropping
    /// one silently (unlike `session.flag clear`, whose `--target` is meaningless anyway — here a target
    /// looks like it was honored). `--select` is single-target by nature — it selects a session to realize
    /// its surface, which N sessions cannot share — and only an EXPLICIT `true` conflicts: the CLI always
    /// sends the field, so testing for presence would reject every CLI broadcast.
    ///
    /// An EMPTY `targets` array is an ERROR, deliberately unlike an empty FLAGGED set (`ok`,
    /// `affected: 0`): "every flagged session" with none flagged is an honest zero, while an empty explicit
    /// list means the caller's dynamic target list came out empty, and falling back to `active` there would
    /// type the text into a session nobody named — an injection into a live shell cannot be taken back.
    func dispatchSessionType(_ request: ControlRequest) async -> ControlResponse {
        guard let text = request.args?.text else {
            return ControlResponse(ok: false, error: "session.type requires text")
        }
        let args = request.args
        let targets = args?.targets
        let flagged = args?.flagged == true
        if flagged, targets?.isEmpty == false {
            return ControlResponse(ok: false, error: "session.type takes --flagged or --target, not both")
        }
        if args?.select == true, flagged || (targets?.count ?? 0) > 1 {
            return ControlResponse(ok: false, error: "session.type --select works with a single target only")
        }
        let options = ControlSessionTypeOptions(text: text, select: args?.select ?? false, pane: args?.pane)
        if flagged {
            return await actions.typeSessions([], flagged: true, window: args?.window, options: options)
        }
        if let targets {
            guard let first = targets.first else {
                return ControlResponse(ok: false, error: "session.type requires at least one --target")
            }
            // a one-element array is the singular form, like the batch `session.close`/`session.move`.
            if targets.count == 1 {
                return await actions.typeSession(first, window: args?.window, options: options)
            }
            return await actions.typeSessions(targets, flagged: false, window: args?.window, options: options)
        }
        return await actions.typeSession(request.target, window: args?.window, options: options)
    }

    func dispatchSessionBackground(_ request: ControlRequest) -> ControlResponse {
        // The args bag is normalized into the option struct here so the app-side adapter stays a small
        // fixed-arity signature (swiftlint function_parameter_count) rather than a 10-parameter dispatch.
        if let fit = request.args?.fit, !WatermarkConfig.isValidFit(fit) {
            return ControlResponse(ok: false, error: "invalid fit: \(fit) (contain|cover|stretch|none)")
        }
        if let position = request.args?.position, !WatermarkConfig.isValidPosition(position) {
            return ControlResponse(ok: false, error: "invalid position: \(position)")
        }
        if let opacity = request.args?.opacity, !WatermarkConfig.isValidOpacity(opacity) {
            return ControlResponse(ok: false, error: "invalid opacity: \(opacity) (0.0-1.0)")
        }
        let watermark: BackgroundWatermark?
        switch request.args?.mode {
        case "image":
            guard let path = request.args?.path, !path.isEmpty else {
                return ControlResponse(ok: false, error: "session.background image requires a path")
            }
            guard WatermarkConfig.isValidImagePath(path) else {
                return ControlResponse(ok: false, error: "image path must not contain control characters")
            }
            watermark = BackgroundWatermark(kind: .image, imagePath: path, opacity: request.args?.opacity,
                                            fit: request.args?.fit.flatMap(BackgroundWatermark.Fit.init(rawValue:)),
                                            position: request.args?.position.flatMap(BackgroundWatermark.Position.init(rawValue:)),
                                            repeats: request.args?.repeats)
        case "text":
            guard let text = request.args?.text, !text.isEmpty else {
                return ControlResponse(ok: false, error: "session.background text requires text")
            }
            guard text.count <= WatermarkConfig.maxTextLength else {
                return ControlResponse(ok: false,
                                       error: "session.background text too long (max \(WatermarkConfig.maxTextLength) characters)")
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            watermark = BackgroundWatermark(kind: .text, text: text, colorHex: request.args?.color,
                                            opacity: request.args?.opacity,
                                            fit: request.args?.fit.flatMap(BackgroundWatermark.Fit.init(rawValue:)),
                                            position: request.args?.position.flatMap(BackgroundWatermark.Position.init(rawValue:)))
        case "color":
            // No per-call opacity: a solid color honors the window translucency set in Settings, applied at
            // emit time via `WatermarkConfig.overlayText(windowOpacity:)` (see `GhosttySurfaceView`).
            guard let color = request.args?.color, !color.isEmpty else {
                return ControlResponse(ok: false, error: "session.background color requires a color")
            }
            guard WatermarkConfig.isValidColorHex(color) else {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            watermark = BackgroundWatermark(kind: .color, colorHex: color)
        case "clear", .none:
            watermark = nil
        default:
            return ControlResponse(ok: false,
                                   error: "invalid background mode: \(request.args?.mode ?? "") (image|text|color|clear)")
        }
        return actions.setSessionBackground(request.target, window: request.args?.window,
                                            options: ControlSessionBackgroundOptions(watermark: watermark))
    }

    func dispatchSessionText(_ request: ControlRequest) -> ControlResponse {
        let all = request.args?.all ?? false
        let lines = request.args?.lines
        if all, lines != nil {
            return ControlResponse(ok: false, error: "use either --all or --lines, not both")
        }
        if let lines, lines <= 0 {
            return ControlResponse(ok: false, error: "--lines must be greater than 0")
        }
        return actions.readSessionText(request.target, window: request.args?.window,
                                       options: ControlSessionTextOptions(pane: request.args?.pane,
                                                                          all: all,
                                                                          lines: lines))
    }
}
