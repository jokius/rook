import rookCore
import AppKit
import GhosttyKit
import SwiftUI

/// The surface's callback entry points: everything the C layer (`GhosttyCallbacks`) hops onto the main actor
/// to deliver — OSC 7 pwd, OSC set-title, child exit — plus the text/selection/search/config operations the
/// app drives the surface with. Split out of `GhosttySurfaceView.swift` to keep that file under the swiftlint
/// size limit; behavior is unchanged.
extension GhosttySurfaceView {
    // MARK: - Callback entry points

    func applyPwd(_ rawPwd: String) {
        // Already on the main actor (the callback hops via DispatchQueue.main.async).
        // `currentCwd` is observed, so the sidebar row refreshes live.
        //
        // Strip control characters from the OSC 7 value first: it flows unquoted into a /bin/sh -c
        // line via {AGT_SESSION_PWD} and into every cwd-inheriting spawn (split/overlay/restore), so a
        // newline (an sh -c command separator) must never survive; a real path has no control chars.
        let pwd = TerminalText.sanitized(rawPwd)

        // This deliberately does NOT save(): OSC 7 fires on every cd/prompt redraw,
        // so persisting here would thrash the disk. Live cwd is persisted on quit
        // and on structural mutations (add/close/move/rename/select), not on every
        // cd, so a crash/force-quit loses only cwd changes since the last save.
        //
        // Guard on a real value change: OSC 7 re-emits the same pwd on every prompt
        // redraw, so an equal write would still notify @Observable observers and churn
        // the sidebar reconcile for nothing.
        if isSplitPane {
            if session?.splitCwd != pwd { session?.splitCwd = pwd }
        } else {
            if session?.currentCwd != pwd { session?.currentCwd = pwd }
        }
    }

    func applyTitle(_ rawTitle: String) {
        // Already on the main actor (the callback hops via DispatchQueue.main.async).
        // `oscTitle`/`splitTitle` are observed, so the sidebar row and window title refresh live. Like
        // applyPwd, this deliberately does NOT save(): OSC set-title re-fires on every prompt redraw.
        //
        // Strip control characters first (the title flows unquoted into a /bin/sh -c line via {AGT_SESSION_NAME},
        // where a newline is a command separator), then a coding agent's progress marker — the sidebar carries the
        // agent as a LOGO, and collapsing every spinner frame to one title lets the guard below swallow the re-emits.
        let title = TerminalText.withoutAgentMarker(TerminalText.sanitized(rawTitle))

        // Guard on a real value change so an equal re-emit doesn't notify observers and churn the sidebar.
        if isSplitPane {
            if session?.splitTitle != title { session?.splitTitle = title }
        } else {
            if session?.oscTitle != title { session?.oscTitle = title }
        }
    }

    func handleProcessExit() {
        // Already on the main actor (the close callbacks hop via DispatchQueue.main.async). Ask the app
        // to close the owning session/overlay, which tears down this surface and removes its sidebar row.
        // Idempotent: the SHOW_CHILD_EXITED action and close_surface_cb can both fire for one exit.
        guard !didHandleProcessExit else { return }
        didHandleProcessExit = true
        onExit?()
    }

    /// Whether a child-exit should close this surface immediately (suppressing ghostty's "press any key"
    /// prompt). True only for a command surface (the overlay) that did NOT opt into the wait prompt; a
    /// `waitAfterCommand` overlay keeps the prompt and closes via `close_surface_cb` after the keypress.
    /// `nonisolated` so the C action callback can read it without a main-actor hop; both backing fields
    /// are immutable `let`s set in `init`, so the read is data-race-free.
    nonisolated var shouldCloseOnChildExitAction: Bool { command != nil && !waitAfterCommand }

    /// Types `text` into this surface's pty (the control channel's `session.type`) as literal keystrokes,
    /// the same path the keyboard uses (`ghostty_surface_key` with `.text` set — see `insertText`). It does
    /// NOT use `ghostty_surface_text`, which wraps writes in bracketed-paste escapes that both suppress
    /// command execution and leak `\e[200~`/`\e[201~` markers when fired rapidly. Printable runs are sent as
    /// key-with-text events; every line ending (`\n`, `\r`, or `\r\n`) is a real Return keypress, so a
    /// trailing newline submits the command and a multi-line payload runs line by line. The bytes are
    /// copied via `withCString`, so no buffer must outlive the call. Returns `false` (a no-op) when the
    /// surface has not been created yet (a never-shown / just-shown session), so a caller injecting into a
    /// pane with no realize/select path (`right`/`scratch`) can report `session not realized` instead of a
    /// false ok; the main-pane path realizes it first via select+poll.
    @discardableResult
    func inject(text: String) -> Bool {
        guard let surface else { return false }
        for segment in KeystrokeSegments.split(text) {
            switch segment {
            case let .text(segment):
                segment.withCString { ptr in
                    var ke = ghostty_input_key_s()
                    ke.action = GHOSTTY_ACTION_PRESS
                    ke.text = ptr
                    _ = ghostty_surface_key(surface, ke)
                }
            case .returnKey:
                sendReturn(to: surface)
            }
        }
        return true
    }

    /// Inserts `text` into this surface as a bracketed paste — the drag-drop path. Unlike `inject(text:)`,
    /// which types keystrokes and turns each `\n`/`\r` into a Return, this routes through `ghostty_surface_text`,
    /// whose bracketed-paste wrapping makes the running program treat the whole payload as literal text, so a
    /// dropped multi-line selection lands at the cursor without auto-submitting — exactly like ⌘V paste. The
    /// guarantee tracks the program's bracketed-paste mode (a raw prompt with mode 2004 off still submits, the
    /// same caveat as ⌘V). A drop must behave like a paste, not like typing; `session.type` keeps `inject`
    /// because automation DOES want newline→Return. The bytes are copied synchronously, so nothing must
    /// outlive the call. A no-op when the surface has not been created yet (a never-shown session).
    func insertPasted(text: String) {
        guard let surface, !text.isEmpty else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    }

    /// Returns this surface's current selection text (the control channel's `session.copy`), or nil when
    /// there is no selection or the surface has not been created yet. The selection is a property of the
    /// surface's terminal state, independent of focus, so any realized session can be read. The libghostty
    /// buffer is copied into a Swift `String` and freed via `ghostty_surface_free_text` before returning.
    func readSelection() -> String? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var t = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &t) else { return nil }
        defer { ghostty_surface_free_text(surface, &t) }
        guard let ptr = t.text, t.text_len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(t.text_len)), as: UTF8.self)
    }

    /// This surface's terminal buffer as plain text (the control channel's `session.text`). Returns nil only
    /// on a FAILED read — the surface does not exist yet or `ghostty_surface_read_text` fails — so the caller
    /// can distinguish that from a genuinely blank screen, which reads as an empty string. The region is the
    /// visible screen by default, or the whole screen plus scrollback when `all` is true or `lines` is set;
    /// `lines` keeps the last N CONTENT lines (trailing blank grid rows trimmed). Like `readSelection`, the
    /// read ignores focus and the libghostty buffer is copied into a Swift `String` and freed before
    /// returning. UTF-8 only: `ghostty_surface_read_text` carries no per-cell color or SGR. Covered by the
    /// `session.text` XCUITest e2e rather than a unit test, since the call needs a live surface.
    func readScreenText(all: Bool, lines: Int?) -> String? {
        guard let surface else { return nil }
        // A zero-init ghostty_point_s is GHOSTTY_POINT_ACTIVE / GHOSTTY_POINT_COORD_EXACT (both enum 0),
        // not viewport/top-left, so set tag and coord on both endpoints.
        let tag = (all || lines != nil) ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
        var sel = ghostty_selection_s()
        sel.top_left = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        sel.bottom_right = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        sel.rectangle = false
        var t = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &t) else { return nil }
        defer { ghostty_surface_free_text(surface, &t) }
        // A successful read of a blank screen yields no bytes — that is an empty string, NOT a failure
        // (nil is reserved for the guards above so `readText` can report a real read failure as an error).
        guard let ptr = t.text, t.text_len > 0 else { return "" }
        let full = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(t.text_len)), as: UTF8.self)
        guard let n = lines, n > 0 else { return full }
        // Drop trailing blank/whitespace-only rows (the unused grid below a short screen) so `--lines N`
        // returns the last N CONTENT lines instead of blank padding, then keep the last N.
        var rows = full.components(separatedBy: "\n")
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.removeLast()
        }
        return rows.suffix(n).joined(separator: "\n")
    }

    /// This surface's foreground process pid (libghostty `ghostty_surface_foreground_pid`), or nil when
    /// the surface has not been created or the call returns 0. Read at quit by the restore-running-command
    /// capture (`ForegroundProcess.command(for:shellBasename:)`); not focus-dependent, like `readSelection`.
    func foregroundPid() -> pid_t? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        return pid > 0 ? pid_t(pid) : nil
    }

    /// Synthesizes a Return keypress (press + release) on `surface` via the same key path the keyboard
    /// uses, so the shell treats it as Enter. Keycode 36 is the macOS virtual keycode for Return.
    private func sendReturn(to surface: ghostty_surface_t) {
        var ke = ghostty_input_key_s()
        ke.keycode = 36
        ke.mods = GHOSTTY_MODS_NONE
        ke.consumed_mods = GHOSTTY_MODS_NONE
        ke.composing = false
        ke.text = nil
        ke.unshifted_codepoint = 0
        ke.action = GHOSTTY_ACTION_PRESS
        _ = ghostty_surface_key(surface, ke)
        ke.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, ke)
    }

    /// Triggers a libghostty keybind action on this surface (e.g. `increase_font_size:1`,
    /// `decrease_font_size:1`, `reset_font_size`), so a menu item can drive the same behavior
    /// as the built-in keybind. A font change rides the usual CELL_SIZE → persist path. Returns
    /// whether the action ran: `false` when the libghostty surface isn't realized yet (the view
    /// exists but its inner `surface` is nil), so a control caller can report `session not realized`
    /// instead of a false ok. `@discardableResult` keeps the GUI/menu callers unchanged.
    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        return true
    }

    /// The direction `navigateSearch` steps the selection. The pure enum (with its libghostty mapping)
    /// lives host-free in `rookCore.SearchDirection`; this alias keeps the existing
    /// `GhosttySurfaceView.SearchDirection` call sites unchanged.
    typealias SearchDirection = rookCore.SearchDirection

    /// Enters search mode on this surface (the `start_search` binding action). libghostty replies with a
    /// START_SEARCH action carrying the current needle; sending it again while search is active closes it.
    func startSearch() { performBindingAction("start_search") }

    /// Sets the search query (the `search:<needle>` binding action). libghostty replies with SEARCH_TOTAL
    /// and SEARCH_SELECTED actions for the new match set.
    func sendSearchQuery(_ needle: String) { performBindingAction("search:\(needle)") }

    /// Steps the selection one match. The rook direction is INVERTED to libghostty's `navigate_search`
    /// string by `SearchDirection.ghosttyAction` (see `rookCore.SearchDirection`), so the DOWN chevron /
    /// Enter / `--next` move visually down and the UP chevron / Shift-Enter / `--prev` move visually up.
    func navigateSearch(_ direction: SearchDirection) {
        performBindingAction(direction.ghosttyAction)
    }

    /// Exits search mode on this surface (the `end_search` binding action). libghostty replies with an
    /// END_SEARCH action.
    func endSearch() { performBindingAction("end_search") }

    /// Applies a rebuilt ghostty config to this live surface (font/theme change from Settings).
    /// `update_config` re-applies the whole config including font-size, so any runtime cmd-+/-
    /// zoom resets to the config default — the caller clears the per-session overrides to match.
    func applyConfig(_ config: ghostty_config_t) {
        guard let surface else { return }
        ghostty_surface_update_config(surface, config)
    }

    /// Builds this session's background-watermark config overlay (base files + `background-image*` lines +
    /// the session's current font zoom, via `WatermarkConfig`/`WatermarkRenderer`) and pushes it to the
    /// surface, retaining the config for teardown. A no-op when the surface has no owning session (the
    /// overlay/scratch/quick-terminal surfaces never carry one). A nil watermark with no font override
    /// yields the plain base config, which CLEARS a previously-applied image. The `.text` PNG is (re)rendered
    /// here so it always matches the current string/color. Main-actor; reads the session imperatively.
    func applyWatermarkFromSession() {
        guard let surface, let session else { return }
        let resolvedImagePath = WatermarkRenderer.materialize(session.backgroundWatermark, sessionID: session.id)
        let overlay = WatermarkConfig.overlayText(watermark: session.backgroundWatermark,
                                                  resolvedImagePath: resolvedImagePath, fontSize: session.fontSize,
                                                  windowOpacity: GhosttyApp.shared.windowOpacity)
        guard let config = GhosttyApp.shared.configWithOverlay(overlay) else {
            NSLog("watermark: per-surface config build failed for session %@", session.id.uuidString)
            return
        }
        ghostty_surface_update_config(surface, config)
        // free the PRIOR per-surface config(s) and keep only this one: after `update_config` installs the
        // new config the surface no longer references the old, so freeing it here is safe AND caps the
        // retain at one per surface. Without this, `config.reload` (scriptable) re-applies each watermarked
        // surface every reload and would grow `ownedConfigs` unbounded on a reload loop.
        ownedConfigs.forEach { ghostty_config_free($0) }
        ownedConfigs = [config]
    }

    /// Re-assert the session's per-surface config (watermark and/or font zoom) after a global config
    /// reload broadcast the shared config to this surface via `applyConfig`, wiping both. No-op when the
    /// session carries neither (so a plain surface isn't needlessly rebuilt). Called from
    /// `GhosttyApp.reloadConfig`; on the zoom-CLEARING reload paths `session.fontSize` was already nil'd
    /// before the broadcast, so only a watermark re-applies there — the appearance-flip reload skips the
    /// reset, and this is what carries each session's zoom across the flip.
    func reapplySessionConfigIfNeeded() {
        guard session?.backgroundWatermark != nil || session?.fontSize != nil else { return }
        applyWatermarkFromSession()
    }

    /// Re-assert a SOLID-color session background after a window-opacity change. A `.color` background
    /// bakes the current window opacity into its per-surface `background-opacity` at apply time (see
    /// `WatermarkConfig.overlayText`), so a live opacity change must re-emit it to keep the color tracking
    /// the slider. No-op unless the session carries a `.color` background — an image/text watermark has a
    /// fixed opacity and must NOT re-render (a `.text` PNG rebuild) on every opacity tick.
    func reapplyColorBackgroundIfNeeded() {
        guard session?.backgroundWatermark?.kind == .color else { return }
        applyWatermarkFromSession()
    }

    /// Applies a solid background color to a sessionless OVERLAY surface (`session.overlay.open
    /// --background-color`). Mirrors `applyWatermarkFromSession`'s `.color` path but reads the overlay's
    /// own `overlayBackgroundColorHex` + `initialFontSize` instead of a session — the overlay carries no
    /// `session`, so that path skips it. Bakes the window translucency into `background-opacity` at open
    /// time (the ephemeral overlay gets no live updates, so it does not re-track a later opacity change —
    /// unlike a session `.color`). A no-op — or a malformed hex, rejected by the leading `isValidColorHex`
    /// guard — leaves the plain base config. Retains the per-surface config in `ownedConfigs`, freed on teardown.
    func applyOverlayBackgroundColor() {
        guard let surface, let hex = overlayBackgroundColorHex, WatermarkConfig.isValidColorHex(hex) else { return }
        let overlay = WatermarkConfig.overlayText(watermark: BackgroundWatermark(kind: .color, colorHex: hex),
                                                  resolvedImagePath: nil, fontSize: initialFontSize.map(Double.init),
                                                  windowOpacity: GhosttyApp.shared.windowOpacity)
        guard let config = GhosttyApp.shared.configWithOverlay(overlay) else {
            NSLog("overlay background: per-surface config build failed")
            return
        }
        ghostty_surface_update_config(surface, config)
        ownedConfigs.forEach { ghostty_config_free($0) }
        ownedConfigs = [config]
    }

    /// The surface's live font size in points (post cmd +/-), read from `inherited_config`; nil when the
    /// libghostty surface isn't realized yet or hasn't resolved a size. The read side of `font.*` — the
    /// control `tree` reads it per pane so a script can query what a font change set (the split/scratch
    /// panes' sizes are otherwise unobservable, being live-only).
    func currentFontSize() -> Double? {
        guard let surface else { return nil }
        let size = Double(ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_WINDOW).font_size)
        return size > 0 ? size : nil
    }

    func reportFontSize() {
        // Already on the main actor (the CELL_SIZE callback hops via DispatchQueue.main.async).
        // currentFontSize reads the surface's live font size; nil means libghostty hasn't resolved one
        // yet, so skip it. The store no-ops a same-value write.
        guard let size = currentFontSize() else { return }
        onFontSizeChange?(size)
    }

    /// Draws the surface now, servicing libghostty's `GHOSTTY_ACTION_RENDER` demand. Main-actor.
    func renderNow() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
    }
}
