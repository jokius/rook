import Foundation

/// A control command name, the `cmd` field of a `ControlRequest`. Raw values are the wire strings
/// the CLI and the socket server agree on; an unknown string fails to decode, which the server
/// turns into an "unknown command" error rather than a crash.
public enum Command: String, Codable, Sendable {
    case tree
    case eventsRead = "events.read"
    case workspaceNew = "workspace.new"
    case workspaceRename = "workspace.rename"
    case workspaceDelete = "workspace.delete"
    case workspaceSelect = "workspace.select"
    case sessionNew = "session.new"
    case sessionDuplicate = "session.duplicate"
    case sessionClose = "session.close"
    case sessionSelect = "session.select"
    case sessionGo = "session.go"
    case sessionRename = "session.rename"
    case sessionReveal = "session.reveal"
    case sessionMove = "session.move"
    case workspaceMove = "workspace.move"
    case workspaceFocus = "workspace.focus"
    case workspaceFilter = "workspace.filter"
    case workspaceColor = "workspace.color"
    case workspaceIcon = "workspace.icon"
    case workspaceRoot = "workspace.root"
    case workspaceCollapse = "workspace.collapse"
    case workspaceExpand = "workspace.expand"
    case sessionType = "session.type"
    case sessionStatus = "session.status"
    case sessionAgent = "session.agent"
    case sessionFlag = "session.flag"
    case sessionSeen = "session.seen"
    case sessionRestore = "session.restore"
    case sessionBackground = "session.background"
    case sessionSplit = "session.split"
    case sessionSplitClose = "session.split.close"
    case sessionScratch = "session.scratch"
    case sessionFileTree = "session.filetree"
    case sessionMarkdown = "session.markdown"
    case sessionFocus = "session.focus"
    case sessionResize = "session.resize"
    case surfaceZoom = "surface.zoom"
    case dashboard
    case sessionCopy = "session.copy"
    case sessionPaste = "session.paste"
    case sessionSelectAll = "session.selectall"
    case sessionText = "session.text"
    case sessionSearch = "session.search"
    case sessionOverlayOpen = "session.overlay.open"
    case sessionOverlayClose = "session.overlay.close"
    case sessionOverlayResize = "session.overlay.resize"
    case sessionOverlayResult = "session.overlay.result"
    case sessionHudOpen = "session.hud.open"
    case sessionHudUpdate = "session.hud.update"
    case sessionHudClose = "session.hud.close"
    case quick
    case quickType = "quick.type"
    case quickText = "quick.text"
    case sidebar
    case sidebarMode = "sidebar.mode"
    case sidebarExpand = "sidebar.expand"
    case sidebarCollapse = "sidebar.collapse"
    case notify
    case fontInc = "font.inc"
    case fontDec = "font.dec"
    case fontReset = "font.reset"
    case windowNew = "window.new"
    case windowList = "window.list"
    case windowSelect = "window.select"
    case windowClose = "window.close"
    case windowRename = "window.rename"
    case windowDelete = "window.delete"
    case windowResize = "window.resize"
    case windowMove = "window.move"
    case windowZoom = "window.zoom"
    case windowFullscreen = "window.fullscreen"
    case windowMinimize = "window.minimize"
    case keymapReload = "keymap.reload"
    case keymapList = "keymap.list"
    case configReload = "config.reload"
    case themeSet = "theme.set"
    case themeList = "theme.list"
    case pickOpen = "pick.open"
    case pickResult = "pick.result"
    case pickCancel = "pick.cancel"
    case restoreClear = "restore.clear"
    /// UI-TEST-ONLY: force the app-level appearance (`light`|`dark` via `args.name`) so an XCUITest can
    /// simulate a macOS light/dark flip; with NO name it READS the side the last config feed applied,
    /// so a test can assert the flip actually drove the reload. The server refuses it outside an
    /// XCUITest launch; deliberately EXEMPT from the four-point keep-in-sync (no CLI subcommand, absent
    /// from the catalog/skill).
    case debugAppearance = "debug.appearance"
}

/// A bag of optional command parameters. Each command reads only the fields it needs; the rest stay
/// nil and are omitted from the JSON, keeping the wire form compact.
public struct ControlArgs: Codable, Sendable, Equatable {
    /// New name for `workspace.new`, `workspace.rename`, `session.rename`; the initial session name
    /// for `session.new` (optional; blank/omitted leaves the auto basename); the theme name for
    /// `theme.set` (omitted/empty selects ghostty's built-in colors / "default ghostty", NOT the
    /// seeded `rook` app default).
    public var name: String?
    /// Working directory for `session.new`.
    public var cwd: String?
    /// Additional session targets for batch-capable commands (`session.close`, `session.move`). When set,
    /// the command uses this ordered list instead of the top-level single `target`.
    public var targets: [String]?
    /// Target workspace for `session.new` (the workspace to add to) and `session.move` (the destination).
    /// Resolved by id / unique prefix / `active`, never by name — use `workspaceName` for name targeting.
    public var workspace: String?
    /// Target workspace BY NAME for `session.new` (mutually exclusive with `workspace`). Reuses the first
    /// workspace with this exact name; an absent name is an error unless `createWorkspace` is set.
    public var workspaceName: String?
    /// For `session.new` with `workspaceName`: create the named workspace when none exists (idempotent
    /// reuse-or-create). An error without `workspaceName` — there is nothing to create by id.
    public var createWorkspace: Bool?
    /// For `workspace.new`: create the workspace already COLLAPSED in the sidebar (the CLI's `--collapsed`)
    /// instead of the default expanded state, so a script can build a workspace and fill it with
    /// `session.new --no-select` without it opening. Omitted/`false` = expanded. The read-back is the
    /// `tree` workspace node's `collapsed` field.
    public var collapsed: Bool?
    /// For `window.new`: create the window already MINIMIZED to the Dock (the CLI's `--minimized`) instead
    /// of presenting it, so a script can build a set of project windows without each one flashing on screen
    /// and stealing focus. Omitted/`false` presents it as usual. The read-back is the `window.list` node's
    /// `minimized` field; the new window also hands frontmost back to a still-visible window, so untargeted
    /// commands do not route into the Dock.
    public var minimized: Bool?
    /// For `session.new`: create the session in the background without selecting or focusing it, leaving
    /// the current selection untouched (the CLI's `--no-select`). Omitted/`false` keeps the default
    /// select-and-focus behavior. The read-back is the existing `tree` `active` flag — the new node is not
    /// `active`.
    public var noSelect: Bool?
    /// For `session.new`: the session the CALLER is running in, stamped by `rookctl` from its own
    /// `ROOK_SESSION_ID`. It decides where an UNADDRESSED create lands — the caller's own window and
    /// workspace instead of whatever window is frontmost and whatever workspace the USER is looking at —
    /// so an agent creating a session while its human browses elsewhere does not scatter sessions across
    /// the tree. Ignored the moment any explicit addressing is present (`window`/`workspace`/
    /// `workspaceName`/`after`/`before`), and ignored (not an error) when it names no live session, so a
    /// stale value degrades to the pre-feature frontmost default.
    public var callerSession: String?
    /// Text to inject for `session.type` / `quick.type`; the search needle for `session.search`.
    public var text: String?
    /// Whether `session.type` may select a never-shown session to realize its surface. For `session.new`
    /// it is the explicit FORCE-select (the CLI's `--select`), overriding the Settings default and
    /// mutually exclusive with `noSelect`.
    public var select: Bool?
    /// Broadcast selector for `session.type`: type into the window's FLAGGED working set instead of a
    /// named target. Mutually exclusive with `targets` (a request carrying both is rejected rather than
    /// silently dropping one) and with `select` (only one session can be selected).
    public var flagged: Bool?
    /// Mode for `session.split` / `quick` / `surface.zoom` (`on|off|toggle`,
    /// `show|hide|toggle` for quick/surface zoom),
    /// `session.flag` (`on|off|toggle|clear`), `sidebar.mode` (`tree|flagged|toggle`),
    /// `workspace.focus` (`on|off|toggle|add`), `workspace.filter` (`on|off|toggle`),
    /// `session.markdown` (`open|close|toggle`),
    /// `window.minimize` (`on|off|toggle`),
    /// `session.background` (`image|text|color|clear`),
    /// and `session.restore` (`set|none|clear` — pin `command`, pin nothing, or drop the pin).
    public var mode: String?
    /// The image file path for `session.background` mode `image` (PNG or JPEG); also the target directory
    /// for `session.filetree` mode `reroot` (re-roots the panel at an arbitrary path instead of the cwd);
    /// also the file `session.markdown` renders (`open`/`toggle`), absolute or relative to the session cwd.
    public var path: String?
    /// The color (`#rrggbb`) for `session.background`: the text tint for mode `text` (nil = the terminal
    /// foreground), or the solid background color for mode `color` (required). Mode `color` takes no
    /// opacity — it honors the Settings window translucency. Also the optional solid background color for
    /// `session.overlay.open` (the overlay pane's own color, independent of the session's); nil = the
    /// default theme background, honoring the same window translucency. And the optional per-call glyph-tint
    /// override for `session.status` (rides the ephemeral indicator, so it lasts only until the next
    /// `session.status` without a color); nil = the Settings-configured status color. And the sidebar icon
    /// tint for `workspace.color` — PERSISTED there (unlike the ephemeral status tint), with the literal
    /// `clear` resetting it to the theme default. And `session.hud.open`'s panel background (same rules as
    /// the overlay's); `session.hud.update` CANNOT change it — the surface reads it once at creation, so an
    /// update ignores this field and the live panel's color survives into the read-back.
    public var color: String?
    /// The per-call glyph-SILHOUETTE override for `session.status` (a `StatusShape` raw value —
    /// `circle|square|triangle|diamond|capsule|star`, parsed and validated in the dispatcher). Rides the
    /// ephemeral indicator like `color`, so it lasts only until the next `session.status` without a shape;
    /// nil keeps that status' semantic default glyph. The second visual axis, for when the tint cannot
    /// carry the state (color blindness, a monochrome theme, a small glyph).
    public var shape: String?
    /// The sidebar icon for `workspace.icon`: an SF Symbol name (`hammer.fill`), a single emoji, or a path
    /// to an SVG/PNG/JPEG (copied into the state dir, so the icon survives the original moving). The
    /// literal `clear` resets it to the default glyph. Classified by `WorkspaceIcon.kind(forRawIcon:)`.
    public var icon: String?
    /// The `background-image-opacity` for `session.background` (image + text), 0...1; nil = ghostty's 1.0.
    public var opacity: Double?
    /// The `background-image-fit` for `session.background` (`contain|cover|stretch|none`); nil = `contain`.
    public var fit: String?
    /// The `background-image-position` for `session.background` (`center` + 8 anchors); nil = `center`. Also
    /// the HUD panel's VERTICAL placement in the pane for `session.hud.open`/`.update` — a `HudPosition` raw
    /// value (`top|center|bottom`), nil = `center`, which the read-back reports either way.
    public var position: String?
    /// The `background-image-repeat` flag for `session.background`; nil = false.
    public var repeats: Bool?
    /// Which split pane to focus for `session.focus` (`left`|`right`|`other`; `other` toggles); also
    /// which pane to read for `session.text` (`left`|`right`; omitted = the focused pane, no `other`),
    /// which pane `session.type` injects into (`left`|`right`; omitted = the left/main pane, the
    /// pre-pane behavior), which pane set `session.status` (`left`|`right`|`scratch`; omitted =
    /// `left`/main, parsed to `StatusPane`), and which pane `session.restore` pins (same `StatusPane`
    /// spelling; omitted = `left`/main, `scratch` rejected app-side).
    ///
    /// `session.overlay.open`/`.close`/`.result` scope to ONE pane with it, parsed to `OverlayPane`, which
    /// takes the `TerminalZoomSurface` spellings minus `scratch` (`left`/`primary`, `right`/`split`);
    /// `scratch` is rejected, there being no scratch pane to cover, and the rejection names only
    /// `left or right` as guidance. Omitted keeps the session-wide overlay, so every existing caller is
    /// unaffected. A pane overlay is always full-pane, so `--pane` conflicts with
    /// `session.overlay.open --size-percent` and `session.overlay.resize` refuses it.
    public var pane: String?
    /// A surface's STABLE spawn token for `session.status --pane-id` and `session.restore --pane-id` (the
    /// shell's baked `ROOK_PANE_ID`, forwarded by the agent-status hook). When it resolves against the
    /// session's live surfaces it OVERRIDES the stale role `pane`, so a status set from a
    /// promoted-then-re-split pane lands on the pane's CURRENT slot; an empty/unknown token falls back to
    /// `pane`. Opaque — validated only by whether it resolves. `session.restore` diverges on the fallback:
    /// an UNRESOLVABLE (non-empty) token with no explicit `pane` is an error there rather than a silent
    /// `left`, since pinning the wrong pane's restore command persists. See `Session.paneRole(forToken:)`.
    public var paneID: String?
    /// Absolute left-pane split fraction (0...1) for `session.resize`, clamped server-side to
    /// `AppStore.splitRatioMin...splitRatioMax`. Mutually exclusive with `ratioDelta`.
    public var ratio: Double?
    /// Signed relative split-divider nudge for `session.resize`: a positive fraction grows the LEFT
    /// pane, negative grows the right (the CLI's `--grow-left`/`--grow-right`). Applied to the session's
    /// current fraction (0.5 when never moved). Mutually exclusive with `ratio`.
    public var ratioDelta: Double?
    /// For `session.text` / `quick.text`: read the full screen + scrollback instead of just the visible screen.
    public var all: Bool?
    /// For `session.text` / `quick.text`: keep only the last N lines of the full buffer.
    public var lines: Int?
    /// Direction for `session.go` (`next`|`prev`|`previous`|`first`|`last`), for the reorder form of
    /// `session.move` / `workspace.move` (`up`|`down`|`top`|`bottom`), and for `session.search`
    /// (`next`|`prev`|`close`).
    public var to: String?
    /// Anchor session (id / unique prefix / `active`) to place a session right AFTER, for the placement
    /// form of `session.new` / `session.move`. The anchor carries its own workspace (resolved across the
    /// whole store), so it self-identifies the destination — mutually exclusive with `to`, `before`, and
    /// the workspace parameter.
    public var after: String?
    /// Anchor session to place a session right BEFORE, the mirror of `after` (mutually exclusive with it).
    public var before: String?
    /// App-run UUID paired with `after` for `events.read`. Both fields are omitted for a bootstrap read.
    public var run: String?
    /// Raw event-kind filters for `events.read`. Validation deliberately happens in the dispatcher so
    /// unknown future kinds produce a normal control error rather than making the request undecodable.
    public var kinds: [String]?
    /// Maximum matching events returned by `events.read`; omitted uses the dispatcher default.
    public var limit: Int?
    /// The desktop-notification title for `notify` (optional; defaults to the target session's name).
    public var title: String?
    /// The desktop-notification body for `notify` (required).
    public var body: String?
    /// The program the overlay terminal runs for `session.overlay.open` (e.g. `revdiff`); also the shell
    /// line `session.restore` pins for the next launch (mode `set` only, typed verbatim — never re-quoted,
    /// which is what lets a pipeline or a compound `&&` line restore at all).
    public var command: String?
    /// The CALLER's own shell (an absolute path), forwarded by `session.new` / `window.new` / `quick` so a
    /// session spawned over the control channel runs the shell of whoever asked for it instead of the app's
    /// default. `rookctl` fills it from its process `$SHELL`; an unset/empty one omits the field entirely,
    /// keeping the request byte-identical to a pre-feature one. Validated for FORM in the dispatcher
    /// (`SurfaceCommand.isValidShellPath`) — existence and executability are app-side.
    ///
    /// Deliberately NOT carried by `session.duplicate`/`session.split`/`session.scratch`: those take the
    /// shell from the session they belong to, so a fish session's split is fish no matter who asked.
    public var shell: String?
    /// Whether a command surface keeps its "press any key to close" prompt after the command exits instead
    /// of closing immediately: `session.overlay.open --wait` (the overlay) and `session.new --command …
    /// --wait` (the primary session surface, held via `Session.commandWait`).
    public var wait: Bool?
    /// For `session.overlay.open`, the percent of the pane (1...100) a *floating* overlay panel
    /// occupies in both dimensions; omitted gives the default full-pane overlay. Also carries the new
    /// size for `session.overlay.resize` (mutually exclusive with `full`), and the caller's OVERRIDE of the
    /// HUD panel's app-measured WIDTH for `session.hud.open`/`.update` — a HUD is always floating, so
    /// omitting it sizes the panel from the message rather than covering the pane, and its height is
    /// measured either way.
    public var sizePercent: Int?
    /// For `session.overlay.resize`, requests the full-pane (translucent, session-hidden) overlay —
    /// the way to switch a floating overlay back to full. Mutually exclusive with `sizePercent`.
    public var full: Bool?
    /// For `session.overlay.open`, whether to select/switch to the target after opening; omitted/false
    /// opens in the background without changing the active session (the default for both full and
    /// floating overlays).
    public var follow: Bool?
    /// The HUD panel's headline for `session.hud.open`/`.update` — required and non-empty on both, since an
    /// update with nothing to say is a close. Wrapped app-side; control characters are rejected.
    ///
    /// Separate from `title`/`body`, which `notify` owns: those two are a desktop notification's fields,
    /// where the title is OPTIONAL and defaults to the session name and the body is the required one.
    /// A HUD inverts that, so sharing them would make each field's contract read "required here, optional
    /// there" — unlike `color`, `position` and `sizePercent`, whose contracts a HUD takes unchanged.
    public var message: String?
    /// The HUD panel's dim second line, wrapped below the message; nil/omitted leaves the panel one block.
    public var detail: String?
    /// The HUD panel's spinner STYLE, a `HudSpinner` raw value; nil/omitted = static, no glyph. The CLI's
    /// bare `--spinner` resolves to `HudSpinner.defaultStyle` before it gets here, so this always names a
    /// style or nothing and the dispatcher has one thing to validate. The box reserves the glyph's cells
    /// either way, so toggling it cannot rewrap the message.
    public var spinner: String?
    /// The finished caller-provided choices for `pick.open`.
    public var items: [ControlPickItem]?
    /// Optional placeholder text for `pick.open`'s query field.
    public var prompt: String?
    /// Initial text in `pick.open`'s query field; a non-empty value opens the picker already filtered.
    public var query: String?
    /// Whether `pick.open` accepts the current query as a custom result.
    public var allowCustom: Bool?
    /// Target window for session/workspace/tree/font commands: id / prefix / `active` (=frontmost).
    /// Selects the window whose tree the command operates on.
    public var window: String?
    /// New window frame width/height in points for `window.resize`.
    public var width: Int?
    public var height: Int?
    /// New window top-left x/y in points for `window.move`, relative to the top-left of the target
    /// display (see `display`); y measured down from the display's top edge.
    public var x: Int?
    public var y: Int?
    /// Target display index (into the screen list) for `window.move`; nil = the window's current display.
    public var display: Int?
    /// Agent state for `session.status` (`idle|active|completed|blocked`).
    public var status: String?
    /// Which coding agent `session.agent` reports (`claude`|`codex`, the `AgentKind` raw value).
    public var agent: String?
    /// The agent's conversation id for `session.agent`, as its own hook reported it; nil CLEARS the pane's
    /// remembered conversation (the pane restores as a plain agent again).
    public var agentID: String?
    /// The agent's config root at launch (`CLAUDE_CONFIG_DIR`/`CODEX_HOME`) for `session.agent`, so the
    /// resume runs against the profile the conversation actually lives in; nil = the agent's default.
    public var configDir: String?
    /// The pid of the agent process that reported `session.agent` — its hook's nearest agent ancestor.
    /// The server accepts the report only when this matches the target pane's foreground pid, which is what
    /// keeps a NESTED agent (a `claude -p` the pane's own agent spawned) from overwriting the pane's
    /// conversation with its own throwaway one. nil skips the check (a caller setting the id by hand).
    public var agentPid: Int?
    /// Whether the `session.status` indicator pulses for attention.
    public var blink: Bool?
    /// Whether the `session.status` indicator resets to idle once the session is visited (selected).
    public var autoReset: Bool?
    /// One-shot sound to play when `session.status` is set (caller-driven, not stored on the indicator):
    /// `default`/`beep` is the system alert sound, any other value is a named system sound
    /// (`NSSound(named:)`, e.g. `Glass`, also resolving custom sounds in `~/Library/Sounds`). nil/empty means
    /// no per-call sound — the app may still play the Settings "Blocked sound" default on a `blocked` status.
    public var sound: String?
    /// The per-slot theme names for `theme.set`: `light` is the light/single slot (an alias for the
    /// positional `name`, so passing both is an error); `dark` sets the dark slot — its presence makes
    /// the app track the macOS appearance (the stored value becomes ghostty's dual `light:,dark:`
    /// form), and the reserved value `none` clears it. Names must be bundled themes.
    public var light: String?
    public var dark: String?
    /// Whether `dashboard` CLOSES the open dashboard instead of opening one (the CLI's `--close`). Mutually
    /// exclusive with targets (the ids to open) and with the font flags — closing takes no other argument.
    public var close: Bool?
    /// The absolute cell font size in points for `dashboard` (the CLI's `--font-size`); must be positive.
    /// Mutually exclusive with `autoSize`.
    public var fontSize: Double?
    /// For `dashboard`, size the cells RELATIVE to the Settings default font size, shrinking as the grid
    /// grows so dense grids stay readable (the CLI's `--auto-size`). Mutually exclusive with `fontSize`.
    public var autoSize: Bool?
    /// For `dashboard`, populate the grid from the target window's most-recently-used sessions (up to 9,
    /// fewer if the window has fewer) instead of explicit ids (the CLI's `--mru`). Mutually exclusive with
    /// `targets` and `close`; composes with the font flags. The MRU resolution is app-side (it needs the
    /// store's recency), so this only signals the intent.
    public var mru: Bool?

    public init(name: String? = nil, cwd: String? = nil, targets: [String]? = nil,
                workspace: String? = nil, workspaceName: String? = nil,
                createWorkspace: Bool? = nil, collapsed: Bool? = nil, minimized: Bool? = nil,
                noSelect: Bool? = nil, callerSession: String? = nil,
                text: String? = nil, select: Bool? = nil, flagged: Bool? = nil,
                mode: String? = nil,
                command: String? = nil, shell: String? = nil,
                wait: Bool? = nil, sizePercent: Int? = nil, full: Bool? = nil,
                follow: Bool? = nil, message: String? = nil, detail: String? = nil, spinner: String? = nil,
                items: [ControlPickItem]? = nil, prompt: String? = nil,
                query: String? = nil, allowCustom: Bool? = nil, window: String? = nil,
                pane: String? = nil, paneID: String? = nil, to: String? = nil,
                after: String? = nil, before: String? = nil, run: String? = nil,
                kinds: [String]? = nil, limit: Int? = nil,
                title: String? = nil, body: String? = nil,
                width: Int? = nil, height: Int? = nil, x: Int? = nil, y: Int? = nil, display: Int? = nil,
                status: String? = nil, blink: Bool? = nil, autoReset: Bool? = nil, sound: String? = nil,
                agent: String? = nil, agentID: String? = nil, configDir: String? = nil, agentPid: Int? = nil,
                ratio: Double? = nil, ratioDelta: Double? = nil,
                path: String? = nil, color: String? = nil, shape: String? = nil,
                opacity: Double? = nil, fit: String? = nil,
                position: String? = nil, repeats: Bool? = nil, all: Bool? = nil, lines: Int? = nil,
                light: String? = nil, dark: String? = nil, icon: String? = nil,
                close: Bool? = nil, fontSize: Double? = nil, autoSize: Bool? = nil, mru: Bool? = nil) {
        self.icon = icon
        self.name = name
        self.cwd = cwd
        self.targets = targets
        self.workspace = workspace
        self.workspaceName = workspaceName
        self.createWorkspace = createWorkspace
        self.collapsed = collapsed
        self.minimized = minimized
        self.noSelect = noSelect
        self.callerSession = callerSession
        self.text = text
        self.select = select
        self.flagged = flagged
        self.mode = mode
        self.command = command
        self.shell = shell
        self.wait = wait
        self.sizePercent = sizePercent
        self.full = full
        self.follow = follow
        self.message = message
        self.detail = detail
        self.spinner = spinner
        self.items = items
        self.prompt = prompt
        self.query = query
        self.allowCustom = allowCustom
        self.window = window
        self.pane = pane
        self.paneID = paneID
        self.to = to
        self.after = after
        self.before = before
        self.run = run
        self.kinds = kinds
        self.limit = limit
        self.title = title
        self.body = body
        self.width = width
        self.height = height
        self.x = x
        self.y = y
        self.display = display
        self.status = status
        self.blink = blink
        self.autoReset = autoReset
        self.sound = sound
        self.agent = agent
        self.agentID = agentID
        self.configDir = configDir
        self.agentPid = agentPid
        self.ratio = ratio
        self.ratioDelta = ratioDelta
        self.path = path
        self.color = color
        self.shape = shape
        self.opacity = opacity
        self.fit = fit
        self.position = position
        self.repeats = repeats
        self.all = all
        self.lines = lines
        self.light = light
        self.dark = dark
        self.close = close
        self.fontSize = fontSize
        self.autoSize = autoSize
        self.mru = mru
    }
}

/// One control request: a command, an optional target (session or workspace id / `active` / prefix),
/// and an optional args bag. One request per connection, newline-delimited JSON.
public struct ControlRequest: Codable, Sendable, Equatable {
    public let cmd: Command
    public var target: String?
    public var args: ControlArgs?

    public init(cmd: Command, target: String? = nil, args: ControlArgs? = nil) {
        self.cmd = cmd
        self.target = target
        self.args = args
    }
}

/// The three forms of the `session.restore` per-pane restore-command override, parsed from the wire tokens
/// `set` / `none` / `clear`. An explicit enum rather than the stored `String?` tri-state, so the wire says
/// which of the three the caller meant instead of leaning on an empty string. `pinNone` is deliberately NOT
/// spelled `none`: a bare `case none` makes the compiler warn "assuming you mean `Optional<T>.none`"
/// wherever the enum appears in an Optional context, which the dispatcher's parse step does.
public enum ControlRestoreOverride: Equatable, Sendable {
    /// wire `set` — pin this shell line, run verbatim on the next launch.
    case pin(String)
    /// wire `none` — pin the pane to nothing, so it restores a plain shell (stored as `""`).
    case pinNone
    /// wire `clear` — drop the pin (stored as nil), back to the captured-foreground auto-restore.
    case unpin

    /// The storage bound on a pinned command, in UTF-8 BYTES (not graphemes) — the value persists in
    /// `windows/<id>.json`, so the cap guards the snapshot, not the display width.
    public static let maxCommandBytes = 1024
}

/// Parsed `session.restore` payload. The pane resolution stays host-side: `paneID` is carried through
/// opaquely and resolved app-side against the session's LIVE surfaces (`Session.paneRole(forToken:)`),
/// falling back to the baked role `pane` — and, unlike `session.status`, an unresolvable token with no
/// explicit `pane` is an error rather than a silent main-pane default.
public struct ControlSessionRestoreUpdate: Equatable, Sendable {
    public let pin: ControlRestoreOverride
    /// Which pane to pin (`left`=main, `right`=split; `scratch` is rejected app-side — the scratch terminal
    /// is never restored), or nil for the main pane.
    public let pane: StatusPane?
    /// The surface's STABLE spawn token (the shell's baked `ROOK_PANE_ID`), forwarded as `--pane-id`.
    public let paneID: String?

    public init(pin: ControlRestoreOverride, pane: StatusPane? = nil, paneID: String? = nil) {
        self.pin = pin
        self.pane = pane
        self.paneID = paneID
    }
}

/// The successful payload: a new/affected id for mutating commands, a tree for `tree`, the selected text
/// for `session.copy`. All optional.
public struct ControlResult: Codable, Sendable, Equatable {
    public var id: String?
    public var tree: ControlTree?
    public var text: String?
    public var windows: [ControlWindowNode]?
    /// The overlay program's exit status for `session.overlay.result` (nil until the program exits).
    public var exitCode: Int?
    /// A count payload for commands whose result is a number, e.g. the keymap-diagnostic count for
    /// `keymap.reload`, the ghostty config-diagnostic count for `config.reload` (counted across ALL config
    /// sources, not just the rook-scoped `ghostty.conf` — libghostty diagnostics carry no source-file
    /// attribution), and the total match count for `session.search` (whose "N of M" display string rides
    /// in `text`).
    public var count: Int?
    /// Number of sessions actually changed by a batch mutation (`session.close` or `session.move`).
    /// Kept separate from `count`, whose CLI rendering is specific to diagnostics/search results.
    public var affected: Int?
    /// The current/affected theme name for `theme.set` (echo) and `theme.list` (current); nil =
    /// ghostty's built-in colors ("default ghostty"), distinct from the seeded `rook` app default.
    public var theme: String?
    /// The available bundled theme names for `theme.list`.
    public var themes: [String]?
    /// The applied (clamped) left-pane split fraction echoed by `session.resize`, so a script can see
    /// where the divider landed after clamping / a relative nudge.
    public var ratio: Double?
    /// The light/dark theme syncing state for `theme.set`/`theme.list`, derived from the stored theme
    /// value: `sync` = whether it is ghostty's dual `light:,dark:` form (the terminal tracks the macOS
    /// appearance), `light`/`dark` = its sides. While syncing, `theme` is absent — the state rides
    /// these three; otherwise `theme` is the plain single theme and `light`/`dark` are absent.
    public var sync: Bool?
    public var light: String?
    public var dark: String?
    /// The resolved keymap plus the live menu key equivalents, for `keymap.list`.
    public var keymap: ControlKeymap?
    /// A page from the app-run event ring, present for `events.read` success and cursor errors.
    public var events: ControlEventBatch?
    /// The current or terminal picker outcome for `pick.result`.
    public var pick: ControlPickResult?

    public init(id: String? = nil, tree: ControlTree? = nil, text: String? = nil,
                windows: [ControlWindowNode]? = nil, exitCode: Int? = nil, count: Int? = nil,
                affected: Int? = nil,
                theme: String? = nil, themes: [String]? = nil, ratio: Double? = nil,
                sync: Bool? = nil, light: String? = nil, dark: String? = nil,
                keymap: ControlKeymap? = nil, events: ControlEventBatch? = nil,
                pick: ControlPickResult? = nil) {
        self.id = id
        self.tree = tree
        self.text = text
        self.windows = windows
        self.exitCode = exitCode
        self.count = count
        self.affected = affected
        self.theme = theme
        self.themes = themes
        self.ratio = ratio
        self.sync = sync
        self.light = light
        self.dark = dark
        self.keymap = keymap
        self.events = events
        self.pick = pick
    }
}

/// Error strings for `session.overlay.result`, shared so the `rookctl --block` poll matches the
/// server's wording exactly (the poll retries while the overlay is still running, by `error` string).
public enum OverlayResultError {
    public static let stillRunning = "overlay still running"
    public static let noResult = "no overlay result"
}

/// Error strings for `session.overlay.*` aimed at a session whose overlay slot holds a HUD. The slot is
/// shared, so these rejections need the live session and fire in `ControlServer`, not the dispatcher.
/// `session.overlay.close` is deliberately absent: closing a HUD is a courtesy the shared teardown gives.
public enum OverlayHudError {
    /// A HUD runs the app's painter, not the caller's program, so there is no status to report — and
    /// `overlayActive` alone would otherwise answer the misleading "overlay still running".
    public static let noResult = "no overlay result: the slot holds a hud"
    /// A HUD is always floating (`AppStore.openHud`): it must never cover the session it is a message about.
    /// A percent is accepted but bounded by `HudLayout.clampSizePercent`, which states the same invariant.
    public static let fullResize = "a hud is always floating: pass --size-percent, not --full"
    /// `session.hud.update`/`.close` against a slot that holds no HUD — empty, or running a caller's program.
    public static let noHud = "no hud"
    /// The body file the helper reads could not be written, so the panel would paint nothing or stale text.
    public static let writeFailed = "could not write the hud message"
}

/// Error strings for the pane-scoped (`--pane`) arm of `session.overlay.*`. Shared because the rejections
/// are split across layers — `alreadyOpen`/`paneNotVisible` need the live session and fire in
/// `ControlServer`, the rest are host-free in `ControlDispatcher+Session` — and the wording must not drift.
public enum PaneOverlayError {
    public static let alreadyOpen = "pane overlay already open"
    public static let paneNotVisible = "pane not visible"
    /// Names the canonical spellings only; `OverlayPane.init?(controlName:)` also takes `primary`/`split`.
    public static let invalidPane = "session.overlay: --pane must be left or right"
    public static let sizePercentConflict = "session.overlay.open: --pane is mutually exclusive with --size-percent"
    public static let resizeUnsupported = "session.overlay.resize: --pane is not supported (pane overlays are always full)"
}

/// Advisory text `notify` returns in `result.text` when the banner toggle is off. The command still
/// succeeds — the unseen badge tracks either way — but nothing is handed to macOS, so a bare `ok`
/// would look identical to a broken notification path. Shared for the same reason as
/// `OverlayResultError`: the server's wording and any caller matching on it must not drift.
public enum ControlNotify {
    public static let bannersOffNote = "badge updated, but \"Show notification banners\" is off, so no banner was posted"
}

/// The single response written back per connection. `ok` gates `result` (on success) vs `error`.
public struct ControlResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public var result: ControlResult?
    public var error: String?

    public init(ok: Bool, result: ControlResult? = nil, error: String? = nil) {
        self.ok = ok
        self.result = result
        self.error = error
    }
}
