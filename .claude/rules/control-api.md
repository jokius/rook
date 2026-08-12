---
paths:
  - "rook/Control/ControlServer*.swift"
  - "rook/Control/ControlTargetResolver.swift"
  - "rookCore/Sources/rookCore/ControlProtocol.swift"
  - "rookCore/Sources/rookCore/ControlResolve.swift"
  - "rookCore/Sources/rookctlKit/*.swift"
  - "rookCore/Sources/rookctl/main.swift"
  - "rook/CLIInstaller.swift"
  - "rook/AgentHooksInstaller.swift"
  - "rook/SkillInstaller.swift"
  - "rookCore/Sources/rookCore/CLIInstall.swift"
  - "rookCore/Sources/rookCore/AgentHooksInstall.swift"
  - "rookCore/Sources/rookCore/SkillInstall.swift"
  - "rookUITests/Control*.swift"
  - "rookUITests/SessionTextUITests.swift"
  - "rook/Resources/agent-skill/**"
---

## Control API

- A programmatic control channel lets an external script drive `rook` over a local unix-domain socket,
  via the companion `rookctl` CLI.
  It is a thin dispatcher onto the existing `AppActions`/`AppStore` seam — the third caller of that seam,
  alongside the toolbar/bottom bar and the menu bar — so no business logic is duplicated.
  Scope is personal scripting: one request per connection, and NO terminal-output/scrollback streaming —
  a buffer is read on demand with `session.text`, never pushed.
  **Event subscription is no longer out of scope** — the inherited "no event subscription (by design)"
  claim is FALSE since `events.read` (catalog below) added the READ leg: a cursor-paged poll over a
  bounded in-process ring of status/notify/session/tree events.
  The server still never PUSHES and holds no long-lived connection, so the request-response model is
  untouched; what changed is that a watcher no longer has to diff `tree` snapshots to find out what
  happened.
- **Three layers, matching the core/app split:**
  1. **Protocol + pure logic in `rookCore`**
     (Foundation-only, `Codable`, `Sendable`): `ControlProtocol.swift` holds the `Command` enum,
     `ControlArgs`, `ControlRequest`, the tree node types (`ControlSessionNode`/`ControlWorkspaceNode`/`ControlTree`),
     `ControlResult`, and `ControlResponse`.
     `ControlResolve.swift` holds the pure target resolver (`resolve(_:candidates:active:) -> TargetResolution`)
     and the socket-path resolver (`socketPath(stateDir:appSupport:)`).
     Shared by both the app and the CLI so the wire contract cannot drift.
  2. **`ControlServer` in the app target**
     (`rook/Control/ControlServer.swift`, `@MainActor`): owns the POSIX unix socket.
     The blocking accept/read loop runs on a background `DispatchQueue`;
     each newline-delimited `ControlRequest` is decoded, hopped to `@MainActor`,
     dispatched onto `AppActions`/`AppStore` (plus a thin `GhosttySurfaceView.inject(text:)` for input),
     and the `ControlResponse` written back before the connection closes.
  3. **`rookctl` CLI**
     in the `rookCore` SwiftPM package: an `rookctlKit` library (the `ParsableCommand` tree — root
     `Rookctl` + shared option/request plumbing in `Commands.swift`, subcommands split by family into
     `SessionCommands.swift`/`WorkspaceCommands.swift`/`WindowCommands.swift`/`MiscCommands.swift` — and
     the socket client in `SocketClient.swift`) plus a thin `rookctl` executable.
     It links `swift-argument-parser`; the `rookCore` library target stays dependency-free.
     Builds with `swift build`, needs no Xcode/GhosttyKit.
- **New/changed control commands are dispatcher-first** (the `refactor`/`hoist` migration, #78 onward).
  A host-free `ControlDispatcher` in `rookCore` (`ControlDispatcher.swift`) now fronts layer 2's dispatch:
  its `dispatch(_:)` owns command parsing, argument validation, error strings, and the success-response
  shape, calling the app through the `ControlActions` protocol, which `ControlServer` conforms to and
  which supplies ONLY target resolution and the AppKit/process side effects.
  Commands migrate group-by-group; one the dispatcher doesn't yet own returns `nil` and falls through to
  `ControlServer`'s existing switch, so that switch is a fallthrough for not-yet-migrated commands, NOT the
  home for new ones.
  So when adding or changing a command: put every host-free part (arg checks, error text, the payload) in
  `ControlDispatcher` with a unit test, and put only the side effect behind a `ControlActions` method — do
  NOT add fresh validation/response logic inline in the `ControlServer` switch.
  (This is the control-channel case of the root `CLAUDE.md` "hoist host-free logic down into `rookCore`"
  module-boundary rule.)
  **Where the app-side arm goes: a per-family file, NOT `ControlServer+SessionActions.swift`.**
  That file is the historical dumping ground and reached the 1000-line swiftlint budget once already,
  which is why recent ports landed their `ControlActions` witnesses in fresh per-family files —
  `ControlServer+WorkspaceCommands.swift`, `ControlServer+KeymapCommands.swift`,
  `ControlServer+EventCommands.swift` — and why the `surface.zoom` family was moved out to
  `ControlServer+SurfaceZoom.swift` (855 lines left behind; the headroom is for breathing room, not for
  the next arm).
  The conformance declaration stays in `+SessionActions.swift`; an extension in any file of the module
  can satisfy it.
  Add the next arm to the matching family file (`+WindowCommands`/`+Appearance`/`+SurfaceIO`/`+WorkspaceCommands`/`+KeymapCommands`/`+EventCommands`/`+SurfaceZoom`)
  or start a new one — do not grow `+SessionActions.swift`.
  A NEW file needs `xcodegen generate` before it builds: the target globs the `rook/` directory, but the
  checked-in `rook.xcodeproj` is generated, so a fresh file is invisible until it is regenerated — the
  symptom is `type 'ControlServer' does not conform to protocol 'ControlActions'` pointing at the
  conformance line, not at the missing file.
- **The four-point audit is the WRITE path; a state-mutating command also owes a READ-BACK field.**
  Whenever a command SETS or MUTATES per-session state, surface that state on `ControlSessionNode` (or
  the tree top-level) so a script can query the value it just wrote: record-then-restore, read-modify-write,
  and idempotency all depend on reading back what a `set`/`resize`/`toggle` changed.
  The read field is populated in `AppStore.controlTree` and, like the other optionals, omitted from the
  JSON when nil.
  Existing pairs to mirror: `session.background`/`background`, `notify`+`session.seen`/`unseen`,
  `session.new --shell`/`shell` (omitted when the session runs the app's default shell),
  `session.status`/`status`+`statusPane`
  (+`statusBlink`/`statusColor`/`statusShape` for `--blink`/`--color`/`--shape`),
  `session.agent`/`agentSession`+`splitAgentSession`,
  `session.flag`/`flagged`, `session.filetree`/`fileTreeVisible`+`fileTreeRoot`,
  `session.markdown`/`markdownPath` (the open file IS the panel's visibility, so one field covers both),
  `session.focus`/`splitFocused`, `session.resize`/`splitRatio`,
  `session.overlay.resize`/`overlaySizePercent`, `session.overlay.open --pane`/`paneOverlays`,
  `session.hud.open`+`session.hud.update`/`hud` (a `ControlHudNode` carrying the whole spec plus the
  EFFECTIVE size on BOTH axes — the slot's own `overlay`/`overlaySizePercent` deliberately read
  false/omitted beside it, since a message is not a running program),
  `sidebar`/`sidebarVisible` (top-level),
  `sidebar.mode`/`sidebarMode`, `workspace.focus`/`marked` + `focused` (workspace node),
  `workspace.filter`/`workspaceFilter` (top-level, `tree`-only) — THREE fields for the focus state, not
  two, because the state itself is two independent bits (which workspaces are marked, and whether the mark
  is applied): `marked` is the membership `workspace.focus` writes, `workspaceFilter` the flag
  `workspace.filter` writes, and `focused` their conjunction, kept as a field of its own so a
  pre-set-era script reading it still means what it used to; see the `workspace.focus`/`workspace.filter`
  section for why the meaning of `focused` was NOT widened instead,
  `workspace.collapse`+`workspace.expand`+`workspace.new --collapsed`/`collapsed` (workspace node),
  `quick`/`quickVisible` (top-level),
  `pick.open`/`pickPending` (top-level, `tree`-only — the pending picker's id; Esc/⌘W resolve a pick with
  no command involved, so a cache-backed copy would go stale),
  `font.*`/`fontSize`+`splitFontSize`+`scratchFontSize` (the per-pane LIVE font size — the split/scratch
  panes' fonts are otherwise unobservable, being live-only; supplied to `controlTree` by app-side closures
  reading `GhosttySurfaceView.currentFontSize()`, since the host-free tree can't read a surface),
  `window.move`+`window.resize`/`geometry`, `window.fullscreen`+`window.zoom`/`fullscreen`+`zoomed`,
  `window.minimize`+`window.new --minimized`/`minimized` (the last four on `window.list`).
  The obligation is scoped to per-session/per-window state, so an APP-GLOBAL command owes no tree field:
  `keymap.list` is itself the read leg of `keymap.reload` (the keymap is one app-wide `SettingsModel`, not
  per-session state), the same way `theme.list` reads back `theme.set` — a sibling READ COMMAND satisfies
  the rule as well as a node field does.
  `events.read` owes no tree field for BOTH halves of that reasoning at once: the ring is one app-wide,
  app-run-scoped buffer (not per-session state that a node could carry), and the command IS a read leg —
  it is what a script uses to observe what the WRITE commands did, so demanding a read-back OF it would be
  circular.
  This is a SEPARATE obligation from the four-point audit (Command + arg + CLI + tests) and easy to forget:
  `session.overlay.resize` shipped write-only and `overlaySizePercent` was added only later, when a
  tmux-zoom script needed to restore an overlay's exact size.
  When adding a state-mutating command, add its read-back field in the SAME change and cover it with a
  `treeSessionNodeRoundTrips…`/`…OmitsWhenNil` round-trip test plus a `controlTree` populate test.
- **Bundling + install.**
  The `rook` target's `Bundle rookctl CLI` postBuildScript (`project.yml`) runs `swift build -c release --product rookctl`,
  copies it to `rook.app/Contents/MacOS/rookctl`, ad-hoc signs the helper,
  then **re-signs the whole app `--deep`** — the phase can run AFTER Xcode's own code-sign on incremental
  builds, so without the re-seal the injected helper breaks the signature (and a shallow re-sign chokes
  on the Debug `rook.debug.dylib`).
  **Help ▸ Install Command Line Tool…** (`rookApp` `CommandGroup(replacing: .help)` → `CLIInstaller.run()`)
  symlinks the bundled binary into `/usr/local/bin` (first entry in macOS's default `/etc/paths`,
  unlike `~/.local/bin`): a direct `FileManager` symlink when the dir is user-writable,
  else a one-time GUI admin prompt via `osascript … with administrator privileges`.
  Pure path/quote logic is `rookCore.CLIInstall` (host-free, unit-tested);
  the AppKit FS + auth glue is `CLIInstaller` (app-side, manually verified like the directory picker).
  Install is GUI-only and keep-in-sync EXEMPT — driving it over the socket is meaningless (you'd need
  `rookctl` already installed to call it).
- **Agent-status hooks install.**
  A second Help entry, **Help ▸ Install Agent Status Hooks…** (`AgentHooksInstaller.run()`),
  wires coding agents to `session.status`.
  The hooks scripts bundle at `rook/Resources/agent-status/` (`rook-agent-status.sh` wrapper +
  `rook-agent-session.sh` (the conversation reporter, below) + `shell/integration.sh`
  + `shell/integration.fish`, a `project.yml` Contents/Resources folder mirroring `Resources/ghostty`).
  The installer copies them to `~/.config/rook/agent-status/`, bakes the bundled `rookctl`'s absolute
  path (`Bundle.main.url(forAuxiliaryExecutable:)`) into the wrapper so the hooks fire even without the
  CLI on PATH, appends a marker-guarded `source` line to `~/.zshrc` + `~/.bashrc`,
  merges four Claude Code hooks into `~/.claude/settings.json` with a `.bak` (UserPromptSubmit→`active --blink`,
  PostToolUse→`active --blink`, Stop→`completed --auto-reset`, Notification[`permission_prompt`]→`blocked`;
  the unmatched PostToolUse re-asserts `active` after every tool so a `blocked` permission prompt clears
  back to active when work resumes — Claude Code has no "permission answered" event,
  and the gated tool's own PreToolUse fires BEFORE `blocked` is set, so the approved tool's PostToolUse
  is the first hook afterwards), and merges SIX Codex lifecycle hooks into `~/.codex/config.toml` with a
  `.bak`.
  **Those Claude hooks also fire inside a Task SUBAGENT under the SAME `session_id`, and the wrapper lets
  those calls THROUGH** — the `agent_type` filter that used to drop them is gone; what the wrapper does read
  from the payload is `background_tasks`, to turn a `completed` reported over live background work into
  `active --blink` (see the Notifications rule).
  The args the installer writes did NOT change.
  **The Codex hooks do NOT map events to statuses — they call a SECOND installed script,
  `rook-codex-status.sh` (`AgentHooksInstall.codexWrapperName`), with an ACTION**
  (SessionStart→`session-start`, UserPromptSubmit→`user-prompt-submit`, PreToolUse→`pre-tool-use`,
  PostToolUse→`post-tool-use`, PermissionRequest→`permission-request`, Stop→`stop`).
  That adapter — not rook's runtime — owns the agent-specific behavior and calls the GENERIC
  `rook-agent-status.sh` wrapper with the same `idle`/`active --blink`/`blocked`/`completed --auto-reset`
  states any caller uses.
  The reason is Codex's **Auto Review**: `PermissionRequest` fires BEFORE Auto Review decides whether a
  human is needed, so mapping it straight to `blocked` false-flagged every auto-approved tool.
  Instead `permission-request`/`user-prompt-submit` fork ONE watcher per pane that polls
  `rookctl session text` (0.5 s, `ROOK_CODEX_WATCH_INTERVAL`/`_MAX_CHECKS` knobs) and reports `blocked`
  only once a real approval/question dialog is VISIBLE in the footer — restoring `active --blink` when it
  clears, so a denied request (which fires no follow-up tool event) does not linger blocked.
  A token file guards the watcher: a superseding lifecycle event rewrites it, and the watcher re-checks
  it right before writing so a late `blocked` from a stale pane read can't clobber a newer status.
  **Codex therefore has TWO `blocked` sources**: that footer-dialog watcher, and — since the port of
  upstream `73217925` — the `stop` arm's FINAL-MESSAGE check.
  `stop` reads `last_assistant_message` off the Stop payload on stdin with
  `/usr/bin/plutil -extract last_assistant_message raw -o - -` (the same no-`jq` JSON convention
  `rook-agent-session.sh` uses) and reports plain `blocked` when the message CONTAINS a `?`,
  falling back to `completed --auto-reset` when it is absent, `null`, or unparseable —
  the watcher only ever sees Codex's own dialogs, so an ordinary prose question at the end of a turn
  used to report `completed` and the session stopped asking for you.
  The containment test is deliberately BLUNT: upstream widened it from "ends with `?`" precisely because
  `How deep should I review it? I recommend the full review.` does not trail in one,
  so it also fires on an already-answered question and on a URL —
  that is the knob to narrow if `blocked` gets noisy.
  (The `CodexStatusHookTests` harness must hand the hook an explicit stdin pipe and CLOSE it;
  an inherited stdin that never reaches EOF hangs `plutil -extract … -` and the suite hangs rather than
  fails.)
  This replaced a retired `codex-notify.sh` that keyword-matched the turn's final message and misfired
  both ways (issue #193; the merge also strips the old `notify = [...codex-notify.sh...]` line).
  Both wrappers get the bundled `rookctl` path baked in by `AgentHooksInstaller.bakeRookctlPath` (it
  loops over `wrapperName` + `codexWrapperName`).
  **`mergeCodexConfig` UPGRADES an existing managed block in place** (`refreshManagedCodexBlock`) rather
  than short-circuiting on the marker: without it, a user who installed the old block would never receive
  a hook fix.
  The refresh preserves Codex's trailing `[hooks.state…]` trust records byte-for-byte (Codex appends
  them INSIDE our end marker) and leaves a FOREIGN marker block (one carrying neither of our scripts)
  untouched; an unchanged block still reports `.unchanged`.
  The script itself is covered host-free by `CodexStatusHookTests`, which runs the real
  `rook/Resources/agent-status/rook-codex-status.sh` against a mock `rookctl`/wrapper and drives it
  through a sequence of fake screens.
  The Codex merge PARSES the config with `TOMLDecoder` (a pure-Swift, spec-compliant parser — the one
  dependency `rookCore` links besides swift-argument-parser) to decide the outcome
  (`AgentHooksInstall.CodexMergeOutcome`): marker present → `.unchanged`; the file already defines its own
  `hooks` → `.hooksExist`; the file isn't valid TOML → `.unparseable`; else → `.merged`, a marker-guarded
  append (the same `rcMarkerBegin`/`End` markers as the shell rc files, so comments/layout survive) plus
  removal of a stale top-level `notify` ONLY when its PARSED value points at `codex-notify.sh` (a comment
  merely naming the file, or the user's own notifier, is never touched).
  On `.hooksExist`/`.unparseable` the app leaves the file untouched and surfaces the block for a manual
  add; the merge is gated on `~/.codex` existing (like the fish rc gate).
  Both the Codex and Claude write paths distinguish an ABSENT config from one that EXISTS-but-unreadable
  (the app-side `readExistingConfig`), so a permission/encoding read failure leaves the file untouched
  instead of clobbering it with no backup.
  Codex requires new command hooks to be reviewed (`/hooks`) before they run.
  Idempotent + re-runnable (re-run refreshes the baked path).
  Like the CLI installer, the host-free JSON/TOML-merge / shell-rc-marker / backup-path logic is `rookCore.AgentHooksInstall`
  (unit-tested); `AgentHooksInstaller` (app-side) owns the AppKit FS glue,
  manually verified.
  **The package ALSO installs a THIRD script, `rook-agent-session.sh`, on BOTH agents' `SessionStart`
  event** — the conversation reporter behind `session.agent` / the resume-agent-conversations feature.
  It is a thin pipe: the hook's stdin JSON goes straight into `rookctl session agent <kind> --from-hook`,
  which parses `session_id` itself (`AgentHookPayload`), so the script needs no `jq` and stays no-op-safe
  outside a rook session.
  It rides the SAME install mechanics as the status wrappers (copied to `~/.config/rook/agent-status/`,
  the bundled `rookctl` path baked in by `bakeRookctlPath`, merged into `~/.claude/settings.json` /
  `~/.codex/config.toml` idempotently), and it is a SEPARATE hook entry from the Codex adapter's existing
  `SessionStart`→`session-start` status action — the two fire on the same event and do different things.
  Because it is new, EXISTING users must RE-RUN Help ▸ Install Agent Status Hooks… to get it (the merge
  is idempotent and upgrades the managed block); without it there is no conversation id and a restored
  agent pane falls back to `--continue` / `resume --last`.
- **Pi agent-status extension.**
  When `~/.pi/agent` exists, the installer ALSO drops a Pi lifecycle extension (`rook-status.ts`) into
  `~/.pi/agent/extensions/` (gated like the fish-rc gate), so a Pi agent inside rook reports onto its
  session's row like Claude/Codex: `agent_start` → `active --blink`, `agent_settled` → `completed
  --auto-reset` (Pi's own settled event).
  It DELEGATES to the shared `rook-agent-status.sh` wrapper, guards on `ROOK_SESSION_ID` (no-op outside rook),
  and uses a TYPE-ONLY SDK import so it needs no runtime package.
  Pi has NO permission/question event, so a Pi session is `active`→`completed` only, NEVER `blocked`.
  The host-free path/marker/result logic is `AgentHooksInstall` (the Pi extension paths, the ownership
  marker, and a `PiResult.writeFailed` warning that DEGRADES on an FS error rather than throwing and hiding
  that the Claude/Codex/shell steps succeeded); the destination is read via `readExistingConfig`
  (nil=absent/throw=unreadable) so a non-ENOENT stat error can't read as absent and bypass the ownership
  gate.
  Control-API keep-in-sync EXEMPT (drives the existing `session.status`).
- **Agent skill install (Claude Code + Codex).**
  A third Help entry, **Help ▸ Install Agent Skill…** (`SkillInstaller.run()`),
  copies a bundled, personal-scope Agent Skill to `~/.claude/skills/rook/` AND `~/.codex/skills/rook/`
  so a coding agent running INSIDE a rook session knows how to drive the app over the control channel.
  Claude Code and Codex use the SAME SKILL.md Agent-Skill format (`name`/`description`/`allowed-tools`
  frontmatter + optional reference files; verified against the user's `~/.codex/skills/`),
  so one authored skill serves both.
  The skill is a REFERENCE/knowledge skill (both user-invocable via `/rook` and model-triggered,
  `allowed-tools: Bash(rookctl *)`; the agent-neutral `description` carries the trigger nouns since
  Codex may ignore the extra `when_to_use` field — unknown frontmatter is harmless),
  authored at `rook/Resources/agent-skill/` (`SKILL.md` overview + model + addressing + the command
  summary + the image-display helper + a troubleshooting/reporting pointer;
  `reference.md` full per-command detail + keymap format; `examples.md` rookctl recipes;
  `troubleshooting.md` diagnosing the common problems (keymap editor, custom actions,
  logs) + the bug-issue / feature-Discussion reporting workflow (draft-first,
  scrub, never run `gh` without explicit user approval); `scripts/show-image.sh` the bundled image-display
  helper), bundled via a `project.yml` Contents/Resources FOLDER reference like `agent-status` (the whole
  dir, INCLUDING the `scripts/` subdir, copies verbatim; `SkillInstaller` uses `FileManager.copyItem`
  so the subdir reaches both installs).
  **Image display is NOT a control command** — it's a bundled shell helper:
  `show-image.sh <image> [size%]` opens an overlay (a real pty) and renders the image via the kitty graphics
  protocol, which the pinned ghostty draws NATIVELY — pure `base64` + chunked `\e_G` APC frames,
  NO kitty binary and NO external image tool.
  (The pinned ghostty renders ONLY the kitty graphics protocol; iTerm2 OSC-1337 inline images and sixel
  are `unimplemented` in that build — verified in upstream `src/terminal/osc/parsers/iterm2.zig`,
  the `.File`/`.FilePart`/`.FileEnd`/`.MultipartFile` keys land in the `unimplemented OSC 1337` bucket.
  The agent CANNOT print graphics escapes to its own tool stdout — the harness escapes the control bytes
  — nor run a viewer in its tool shell — no `/dev/tty`; the overlay sidesteps both,
  so the method is agent-harness-agnostic and works identically for Codex.) It is invoked by absolute
  install path (`~/.claude/skills/rook/scripts/show-image.sh` or `~/.codex/...`),
  NOT `${CLAUDE_SKILL_DIR}` — that token is Claude-Code-only and would not expand in the Codex copy of
  the SAME authored `SKILL.md`.
  **Install policy:** write to each agent base that EXISTS (`~/.claude` and/or `~/.codex`);
  if neither, fall back to creating `~/.claude` (`SkillInstall.installTargets`).
  Pure file-drop (no manifest): per-target remove-then-copy for a clean reinstall,
  best-effort per agent (one failing doesn't abort the other), but it REFUSES to clobber a same-named
  skill the user authored (one whose `SKILL.md` lacks the `<!-- rook-skill -->` marker — `SkillInstall.mayOverwrite`).
  Host-free path/target/marker logic is `rookCore.SkillInstall` (unit-tested);
  `SkillInstaller` (app-side) owns the AppKit copy, manually verified.
  Install is GUI-only and keep-in-sync EXEMPT (a skill that documents the socket isn't itself driven
  over it).
  **KEEP-IN-SYNC (HARD): the bundled skill is a documentation mirror of the control surface — whenever
  you change the Control API (commands/args/returns), the keymap format,
  or the window/workspace/session/pane model, update `rook/Resources/agent-skill/` (SKILL.md + reference.md
  + examples.md + `troubleshooting.md` + `scripts/`, incl. the command count) so the installed agent-driver
  doc stays accurate.
  It is the fourth keep-in-sync surface alongside the GUI/menu/CLI.
  The skill's `troubleshooting.md` mirrors the user-facing `docs/troubleshooting.md`;
  keep the two in step when a diagnostic path or the reporting workflow changes.**
- **Socket path / lifecycle.**
  The path is `<ROOK_STATE_DIR>/rook.sock` when `ROOK_STATE_DIR` is set (state isolation),
  else `<app support>/rook.sock` (`~/Library/Application Support/rook`),
  via `ControlResolve.socketPath`.
  `ControlServer.defaultSocketPath()` adds an `ROOK_CONTROL_SOCKET` env override that takes precedence
  (used by XCUITests, whose sandboxed `ROOK_STATE_DIR` container path exceeds the `sun_path` ~104-byte
  limit); the CLI's `--socket` flag is the user-facing equivalent.
  The socket is `chmod 0600`.
  Each accepted connection sets `SO_RCVTIMEO` (5 s, alongside `SO_NOSIGPIPE`) so a stalled client can't
  wedge the serial accept loop — a timed-out `read()` returns `EAGAIN`, which `readLine` (any non-`EINTR`
  `n < 0` = end-of-read) maps to nil → close → `accept()` resumes.
  `start()` is idempotent (the scene `.task` may re-run) and unlinks any stale path before binding;
  it is best-effort (a bind failure logs and the app still launches).
  Lifecycle is asymmetric: started from the scene `.task`, stopped from `AppDelegate.applicationWillTerminate`;
  a force-quit that skips that leaves a stale socket file, which the next launch's unlink-first handles.
- **Ownership is a `flock`, taken at INIT — a second instance refuses the path instead of stealing it.**
  `ControlServer.init` opens `<socketPath>.lock` and takes an exclusive non-blocking `flock`;
  `start()` refuses to bind while another process holds it.
  Nothing on disk distinguishes a live socket from a force-quit leftover, and unlinking a live one strands
  its owner: it keeps its listening fd, never learns it is unreachable, and only a restart recovers it.
  The decision happens at INIT, not in `start()`, because the launch window's surfaces are built during the
  initial render pass and SNAPSHOT `ROOK_SOCKET` into the pty environment, while `start()` only runs from
  the scene's `.task` afterwards — deciding there would hand the first shell the owner's live socket.
  `start()` retries acquisition for the instance refused while the owner was still alive, guarding on the
  held fd first: `flock` is per open file description, so re-opening a file this process already locked
  conflicts with itself.
  Every failure path in `start()` KEEPS the lock (releasing it while still advertising the path is the leak
  the lock exists to close); `stop()` is the only release site, and it releases in a `defer` ABOVE the
  `listenFD >= 0` guard so an instance that never bound does not hold the path for its whole life.
  The lock FILE is never unlinked — the next instance would lock a fresh inode and exclude nobody.
  Do NOT swap the lock for a `connect` probe: on Darwin a live listener whose backlog is full refuses with
  the same `ECONNREFUSED` a socket nobody listens on returns, so one stalled client parking the serial
  accept loop would make a running instance read as stale.
- **A refused instance advertises `<socketPath>.unavailable` through `resolvedSocketPath`**,
  so its shells and `{AGT_SOCKET}` carry a path nothing serves rather than the resolved default,
  which would point them at the other instance — the user's live terminal, where shared state makes
  persisted session ids resolve too.
  Do NOT omit the variable instead: `rook-agent-status.sh` drops `--socket` when it is absent and `rookctl`
  then resolves that same default, so an unset value routes agent status onto the live app.
  `refused` clears on a later successful acquire, since `start()` re-runs per window scene and the owner may
  have quit in between.
  A refused instance's `stop()` returns early without unlinking, leaving the owner's socket intact.
  Covered by `rookTests/ControlServerTests`.
- **Protocol shape.**
  One request per connection, newline-delimited JSON: `{"cmd":…,"target":…,"args":{…}}` → one `{"ok":…,"result":…|"error":…}`
  → close.
  Mutating commands return the affected/new id in `result.id` (create-then-use without a second round-trip);
  `tree` returns `result.tree`.
  An unknown `cmd` fails to decode and comes back as a structured error,
  never a crash; a 1 MiB max-line cap bounds the read buffer.
  In `rookctl`'s human (non-`--json`) output, `result.id` is echoed ONLY for the create commands (`session/workspace/window new`,
  via `RequestCommand.echoesResultID`) where the new id isn't known yet;
  every other mutation prints `ok` (the id you already named is noise).
  The id is always present under `--json`.
  Batch session mutations return the number of sessions actually changed in `result.affected`; human
  output is `1 session` / `N sessions`. `result.count` remains reserved for diagnostics and search.
- **Addressing.**
  UUID is canonical, with sugar: `active` (the selected session / current workspace),
  exact `uuidString` (case-insensitive), or a git-style unique prefix.
  Zero prefix hits → `notFound` error, ≥2 → `ambiguous` error listing the candidates.
  `--target` defaults to `active`, so scripts rarely type an id and never for "the current one".
  Batch-capable session commands (`session.close`, and `session.move` with workspace/after/before placement)
  accept repeated `--target` flags in the CLI; on the wire these are `args.targets: [String]`. The batch is
  scoped to one window/store: the first target resolves by the normal `--window`/frontmost/cross-window
  rules, then remaining targets resolve inside that same store so one command never mutates multiple windows.
  The top-level `target` also carries the first explicit batch target so a new CLI talking to a still-running
  pre-batch server degrades to a named session instead of accidentally acting on `active`.
- **Command catalog (81 commands):**
  The count is every `Command` case MINUS `debug.appearance` (the UI-test-only seam below, which has no
  `rookctl` subcommand and is not in the skill) — `awk '/^public enum Command/,/^}/' rookCore/Sources/rookCore/ControlProtocol.swift | grep -cE '^\s+case '`
  minus one (82 cases → 81).
  Re-RUN that command rather than trusting the number in front of you: it went stale once already, when
  `session.restore` landed and every count surface kept saying 73.
  The same number must appear in `README.md`, `site/docs.html`, `site/commands.html` (four places there:
  the meta description, the two social-card descriptions, and the page intro), and the bundled
  `agent-skill/SKILL.md`;
  those surfaces drifted apart once (67 here vs 66 there) precisely because each was edited alone.
  - `tree`
  - `events.read` — its own family, NOT part of `tree`: the ring is app-wide and the command is a
    cursor-paged read of what HAPPENED, while `tree` is a snapshot of what IS
  - `workspace.new`/`workspace.rename`/`workspace.delete`/`workspace.select`/`workspace.move`/`workspace.focus`/`workspace.filter`/`workspace.color`/`workspace.icon`/`workspace.root`/`workspace.collapse`/`workspace.expand`
  - `session.new`/`session.close`/`session.select`/`session.rename`/`session.duplicate`/`session.reveal`/`session.move`/`session.type`/`session.split`/`session.split.close`/`session.scratch`/`session.filetree`/`session.markdown`/`session.focus`/`session.resize`/`session.go`/`session.copy`/`session.paste`/`session.selectall`/`session.text`/`session.search`/`session.status`/`session.agent`/`session.flag`/`session.seen`/`session.background`/`session.restore`/`session.overlay.open`/`session.overlay.close`/`session.overlay.resize`/`session.overlay.result`/`session.hud.open`/`session.hud.update`/`session.hud.close`
  - `surface.zoom`
  - `dashboard`
  - `pick.open`/`pick.result`/`pick.cancel` — the native picker (see its own section below)
  - `quick`/`quick.type`/`quick.text`
  - `sidebar`/`sidebar.mode`/`sidebar.expand`/`sidebar.collapse`
  - `notify`
  - `font.inc`/`font.dec`/`font.reset`
  - `window.new`/`window.list`/`window.select`/`window.close`/`window.rename`/`window.delete`/`window.resize`/`window.move`/`window.zoom`/`window.fullscreen`/`window.minimize` (see the Windows section)
  - `keymap.reload`/`keymap.list` (see the Keymap section)
  - `config.reload` (see the Settings section)
  - `theme.set`/`theme.list` (see the Theme picker section)
  - `restore.clear` (see the Settings section)

  One extra `Command` case is deliberately NOT part of the catalog: `debug.appearance` (`light`|`dark`
  via `args.name`) is a UI-TEST-ONLY seam that sets `NSApp.appearance` so an XCUITest can simulate a
  macOS light/dark flip (macOS XCUITest has no API for it); the arm ALSO posts
  `.rookSystemAppearanceChanged` directly so the flip pipeline runs deterministically without depending
  on whether KVO fires on an explicit `NSApp.appearance` set (production follows the appearance via an
  app-level KVO observer on `NSApplication.effectiveAppearance` — see the theme-picker/libghostty rules).
  The `ControlServer` arm refuses it outside an XCUITest launch (`ContentView.isUITestLaunch`), it gets
  NO `rookctl` subcommand, and it stays out of the agent skill — a documented keep-in-sync EXEMPTION
  (test scaffolding, not a control surface).
  Setting echoes the resulting effective side in `result.text`; the BARE form (no name) reads the side
  the last config feed applied (`SettingsModel.lastAppliedIsDark`), which the test polls to prove the
  flip actually drove the reload.
  `AppearanceFlipUITests` is its only consumer; the public command count stays 80.

  **`events.read` — the READ leg of a bounded event ring, control-NATIVE (no GUI surface at all).**
  It exists because polling `tree --json` and diffing a ~31-field-per-session snapshot cannot see a
  transition that flipped and flipped BACK between two polls (an agent that blocked and unblocked simply
  never happened), and cannot read notification CONTENT at all — the session node carries only an unseen
  count.
  The ring (`rookCore/Sources/rookCore/ControlEvents.swift`, `ControlEventRing`, `@MainActor`, capacity
  4096) is one buffer per APP RUN, stamped with a run UUID and a monotonic `seq`, holding five kinds:
  - `status` — a status TRANSITION. `AppStore.setAgentIndicator` emits only when the NORMALIZED indicator
    actually changed, so a re-asserted `--pane right` on a splitless session (which coerces to `left`) is
    silent instead of firing on every call.
  - `notify` — a notification's effective title + body (an empty title falls back to the session name).
  - `session.created` / `session.closed` — per session, carrying its display name.
  - `tree.changed` — a per-WINDOW structural signal, debounced 100 ms, so a batch mutation (a multi-session
    move, a workspace reopen, a window remove) collapses into ONE signal rather than N.
    Emitted for name/order/shape changes that a snapshot diff would otherwise have to find; a same-value
    rename is deliberately NOT a tree change.
  Args (all optional): `--run`/`--after` (the cursor, a PAIR), `--kind` (repeatable and/or
  comma-separated), `--limit` (1…1000, default 100).
  Response is `result.events` = `{run, next, items[]}`, each item
  `{seq, ts, kind, window?, workspace?, session?, payload{}}` with nil fields omitted —
  payload is `name`/`status`/`pane`/`blink`/`color` for `status`, `name`/`title`/`body` for `notify`,
  `name` for `session.created`/`session.closed`, and empty for `tree.changed`
  (golden wire shapes are pinned in `ControlEventsTests.everyEventKindMatchesGoldenWireShape`).
  Feed each reply's `next` back as the next `--after`: it is the sequence the ring scanned THROUGH,
  including entries the kind filter skipped — except when `--limit` truncates the page, where `next` is the
  LAST RETURNED match's `seq`, not the tail, so the matches beyond it are not silently consumed.
  **The cursor contract is the delicate part, and every failure is LOUD.**
  - NO cursor (both `--run` and `--after` omitted) is the subscribe-from-now bootstrap: it anchors at the
    tail and returns NO history, because replaying up to 4096 stale events at a fresh consumer is worse
    than useless. `--run <id> --after 0` is the opposite intent — replay everything still retained.
  - One of the pair without the other is rejected by the dispatcher before the ring is touched
    (`events.read requires --run and --after together`) rather than treated as a bootstrap, which would
    silently drop everything since the caller's last page.
    The other dispatcher-owned validations: `invalid event run id`, `invalid event cursor`,
    `event limit must be between 1 and 1000`, `invalid event kind: <kind>`.
  - Three ring-level failures answer `ok: false` — a cursor from a PREVIOUS app run → `event run changed`;
    a cursor past the sequence → `event cursor is ahead of the current sequence`;
    a cursor whose events have already been EVICTED → `event cursor expired`.
    (`ControlEventReadError` raw values; scripts match on these strings, so do not reword them.)
  - **All three still carry the CURRENT anchor** in `result.events` (`{run, next, items: []}`), so a caller
    that decides to rebaseline can do it from the same reply.
    The server never rebaselines silently on the caller's behalf: a consumer that missed events must LEARN
    it missed them instead of mistaking a fresh anchor for "nothing happened" — that is the whole point of
    the feature and the reason a bad cursor is an error rather than an ok-with-new-anchor.
  Unknown kinds stay RAW strings on the wire (`ControlArgs.kinds: [String]`), so a future kind name decodes
  fine and fails as a normal control error rather than making the request undecodable.
  **`rookctl events` is a CLIENT-side poll loop, not a stream**
  (`rookCore/Sources/rookctlKit/EventCommands.swift`): it sends the bootstrap read, prints one line per event, feeds each reply's `next` back as the next
  `--after`, and sleeps 0.25 s ONLY after an EMPTY page — a burst drains at full speed.
  `--json` prints one BARE JSON object per event (NDJSON, pipe it into `jq`); the default is a human
  `HH:mm:ss kind name …` column line.
  It never swallows a failure: a transport error, an `ok:false` (notably a loud cursor failure), or a
  failed stdout write stops the loop.
  It is registered on the root but is NOT a `RequestCommand` — it owns a loop instead of one round trip.
  **Where the pieces live (dispatcher-first, taken to its limit).**
  The ring, the cursor rules, the batch/anchor shape, and ALL of `events.read`'s validation
  (`ControlDispatcher.dispatchEventsRead`) are host-free in `rookCore`;
  the app-target arm is `ControlServer+EventCommands.readEvents`, twelve lines forwarding to
  `WindowLibrary.readEvents`.
  There is NO target to resolve — the ring is app-wide (one per `WindowLibrary`, shared by every window
  store), so `--window` does not apply; each event carries its own `window` field instead.
  Emission rides `AppStore.controlEventSink`, a closure `WindowLibrary.makeStore` supplies that stamps the
  window id onto each draft; a standalone `AppStore` has a nil sink and emits nothing.
  Two side conditions are load-bearing for the stream telling the truth:
  1. `clearAutoResetIndicator` routes the one-shot `completed` flash clear through `setAgentIndicator`
     instead of assigning `session.agentIndicator` directly — a direct assign bypasses the emit, so the END
     of the episode would be invisible and a watcher would see a `completed` that never resolves.
  2. `WindowLibrary.isBootstrapping` (true only while `init` runs `bootstrap()`) IS the launch-restore
     suppression — rook's `loadStore` has no `launchRestore` flag — so every store the launch path opens
     emits into a dead sink and the ring starts empty, instead of replaying the whole restored tree as
     `session.created` and burying a fresh consumer at startup.
     A genuine (re)open is different on purpose: `loadStore` for a REOPENED window emits its sessions as
     `session.created` plus one `tree.changed`, because that tree just became observable again.
  `WindowLibrary.flushTreeEvents()` is a TEST seam that fires the pending per-window debounces
  synchronously; it is deliberately not wired to quit — by then no consumer is left, and the ring does not
  outlive the app run anyway.
  Tests: `ControlEventsTests` (ring semantics + dispatcher validation + golden wire shapes + store/library
  emission, incl. launch silence, the per-window debounce, and the loud-failure mapping),
  `EventCommandsTests` (request building, cursor advance, backoff-only-on-empty, stop-on-failure,
  formatters), and `CommandsTests.eventsIsRegisteredAsAPollingSubcommand`.
  There is NO XCUITest e2e — everything but the socket hop is host-free, which is the point of the seam.
  **The `notify` kind is emitted from BOTH notification paths**, `NotificationManager.notify` (OSC 9/777)
  and `NotificationManager.send` (the control `notify` command).
  Each calls `AppStore.recordNotificationEvent` BEFORE the `bannersEnabled` gate, so a watcher sees every
  ACCEPTED notification — including the ones the banner toggle swallows, which the unseen badge counts
  either way.
  The call also returns the effective title (the session name when the title is empty), and both paths use
  that return value for the banner, so the ring and the banner can never disagree about what was said.
  This leg shipped a beat after the ring itself: `recordNotificationEvent` landed host-free and
  unit-tested while `NotificationManager` sat outside that change's file set, so for one commit the kind
  validated but never fired.

  `workspace.delete` honors keep-at-least-one and returns an error instead of the GUI confirm alert (nothing
  blocks on a modal).
  `session.close` has a legacy single-target control path and a batch path. Single-target control close
  continues to call `AppStore.closeSession` (hard close; backward-compatible with the original control
  behavior). Repeated `--target` / `args.targets` is the GUI-equivalent batch close: it resolves all targets
  in one store and honors `closeGraceUndoEnabled`. When enabled it calls `AppStore.softCloseSessions`,
  producing one grace timer and one grouped undo/reopen record; when disabled it immediately hard-closes
  each resolved session like the GUI. Both return the number actually closed in `result.affected`
  (`ok` with the count — never an error for an empty result, matching the batch `session.move` shape).
  Batch target resolution (`resolveBatchSessions`) is all-or-nothing and deduplicating: any unknown or
  ambiguous target fails the WHOLE request before anything mutates
  (`ControlAPIUITests.testSessionCloseBatchIsAllOrNothing`), and a batch that deduplicates to a single
  session (e.g. `--target a --target a`) takes the single-target path — for close that is the legacy
  HARD close (no grace window), consistent with the one-element `session.move` routing.
  During the grace window, reopening any member restores the whole group but selects the specific Recent
  item the user chose, matching workspace close grouping without losing selection intent. Keep-in-sync: `ControlArgs.targets`, the
  `.sessionClose` dispatcher batch arm, `ControlActions.closeSessions`, `rookctl session close --target`
  repeat support, round-trip/dispatcher/CLI tests, and `ControlAPIUITests.testSessionCloseMultipleTargets`.
  `session.move` is MODE-BEARING with THREE exclusive placement intents:
  `args.to` (`up`|`down`|`top`|`bottom`) REORDERS the session within its own workspace (parses `ReorderDirection`,
  drives `AppStore.reorderSession` → the existing `moveSession(at:)` primitive, returns the session id);
  `args.workspace` RELOCATES it to another workspace (still APPENDS at the end);
  and `args.after`/`args.before` (a session address — id / prefix / `active`) PLACE it directly after/before
  an anchor session (`ControlSessionMove.place(anchor:after:)`).
  The anchor CARRIES ITS OWN WORKSPACE — it is resolved against the store's FULL session set (all workspaces),
  so it names the destination workspace itself and relocates + positions in one shot (cross-workspace
  falls out for free).
  Placement reuses the drag-drop index math host-free: `SidebarDrop.resolveRelative` (the tested "after
  this row" `sessionIndex + 1` + the same-workspace post-removal off-by-one + the anchor==source no-op)
  feeding `AppStore.moveSession(_:toWorkspace:at:)`.
  Exactly one intent must be set: after+before is an error (`"use either --after or --before, not both"`),
  after/before + `--to` is an error (`"session.move takes --after/--before or --to, not both"`),
  after/before + a workspace is an error (`"session.move takes --after/--before or a workspace, not both"`
  — the anchor already names the workspace), both `--to`+workspace and neither are errors,
  and an invalid direction is an error.
  Repeated `--target` / `args.targets` makes `session.move` a batch move for workspace relocation and
  after/before placement. It uses the same host-free block semantics as sidebar multi-drag:
  all moved sessions are resolved in visual tree order, removed first, then inserted as one block via
  `SidebarDrop.resolveSessions`/`AppStore.moveSessions`. Batch `--to up|down|top|bottom` is deliberately
  rejected (`"session.move --target can be repeated only with a workspace or --after/--before"`) because
  relative one-step reorder is inherently per-session and order-dependent.
  The response reports only sessions actually moved in `result.affected`; members already in a workspace
  destination remain in place and are not counted. A one-element `args.targets` array is equivalent to the
  singular form (the dispatcher routes it through `moveSession`), including the `result.id` response and
  moving an existing destination member to the end.
  Keep-in-sync: `ControlArgs.after`/`before` + `ControlSessionMove.place` in `ControlProtocol.swift`/`ControlModes.swift`,
  the `.sessionMove` place-mode routing + guards in `ControlDispatcher`, the app-side `moveSession` place
  case (`ControlServer+SessionActions.swift`, resolving both target + anchor locations and calling
  `resolveRelative`), the `session move --after/--before` CLI, and round-trip / dispatcher / e2e
  (`testSessionMovePlaceWithinWorkspace`, `testSessionMovePlaceCrossWorkspace`, the reject-* guards) tests.
  Batch keep-in-sync additionally includes `ControlArgs.targets`, `ControlActions.moveSessions`,
  `rookctl session move --target` repeat support, and `ControlAPIUITests.testSessionMoveMultipleTargetsWithinWorkspaceBeforeAnchor`.
  Keep-in-sync exemptions for sidebar batch actions: Flag/Unflag is loop-equivalent to repeated
  `session.flag on|off --target <id>` (the plural store API only saves once).
  The GUI's multi-select toggle is NOT a `toggle` loop: `AppActions.toggleFlags` computes ONE uniform
  value for the whole set (`allSatisfy(\.flagged)` — flag all unless every target is already flagged)
  and applies it, so on a mixed selection a per-row `session.flag toggle` loop diverges from the GUI.
  A script wanting the GUI semantics reads `flagged` off `tree`, computes the uniform value, and loops
  `on`/`off`.
  Clear Status is loop-equivalent to repeated `session.status idle --target <id>` and intentionally adds
  no batch command.
  `workspace.move` is the workspace REORDER (control-native, no separate verb):
  `args.to` (`up`|`down`|`top`|`bottom`) resolves the workspace target via the shared `resolveWorkspace`
  (honoring the global `--window` selector like other workspace commands),
  drives `AppStore.reorderWorkspace`, and returns the workspace id; a missing or invalid `to` is an error.
  Drag-and-drop stays the precise (drop-between-rows) surface; the control path is relative-only,
  mirroring `session.go --to`.
  Four-point keep-in-sync audit for `workspace.move`: (1) `case workspaceMove = "workspace.move"` in
  `ControlProtocol.swift` (reuses `ControlArgs.to`, no new field), (2) the `.workspaceMove` dispatch
  arm in `ControlServer`, (3) the `workspace move --to` subcommand in `rookctlKit`,
  (4) round-trip tests in `ControlProtocolTests` plus the e2e in `ControlAPIUITests`.
  NOTE on `workspace.move --target active`: `active` for a workspace resolves to `AppStore.currentWorkspaceID`,
  which with NO selected session falls back to `workspaces.last` — so repeated `workspace.move --to top --target active`
  on a session-less window targets a DIFFERENT (newly-last) workspace each call (consistent with the
  `currentWorkspaceID` fallback contract; address a specific workspace by id/prefix to step the same
  one).
  `session.split` resolves the target id and drives `AppStore.toggleSplit` directly (NOT the argument-less
  `AppActions.toggleSplit()`, which only acts on the active session) — `off` HIDES the split keep-alive,
  mirroring ⌘D (the pane's surface is NOT torn down).
  `split` reports SHOWN, so a hidden split reads false; `hasSplit` reports the pane existing at all and is
  present exactly when `splitRatio`/`splitFocused` can be.
  Callers asking "does this session have a split" read `hasSplit`, and `rookctl tree` tags the hidden case
  `(split hidden)`.
  `session.split.close` is the teardown verb, its own command rather than a fourth `ControlToggleMode`
  value, which is shared with `session.scratch`/`sidebar` and cannot express close (a hidden split is
  already `off`).
  Idempotent: a session with no right pane answers ok.
  Its app-side arm lives in `rook/Control/ControlServer+SplitCommands.swift`, not in the size-capped
  `ControlServer+SessionActions.swift`.
  The palette's Close Split is the GUI twin, a row gated on `hasSplit` with no `BuiltinAction`.
  `session.scratch` (mode `on`|`off`|`toggle`, mirrors `session.split` exactly) shows/hides the **scratch
  terminal** — a THIRD per-session login shell (alongside main + split) that RENDERS like a full overlay
  (full-pane, hides the session, translucent) but BEHAVES like the split:
  lazily spawned on first show, kept alive when hidden (`off` is `AppStore.toggleScratch` keep-alive,
  never a teardown), recreated fresh after its shell's own `exit`.
  NOT persisted (absent from `SessionSnapshot`, like the overlay) — `Session.scratchActive`/`scratchSurface`,
  `AppStore.toggleScratch`/`closeScratch` (the latter only on `exit` + session/workspace/window teardown).
  Full-overlay rendering only (never floating): a conditional `sessionDetail` ZStack sibling at `.zIndex(1)`
  (the structural pattern the now-removed `if fullOverlay` sibling used), BELOW the ephemeral `overlayPanel`
  (`.zIndex(3)` — a normal overlay launched over the scratch sits on top); the panes' opacity/hit-testing gate is `hideForOverlay = fullOverlay || scratchActive`
  (still false for a FLOATING overlay, preserving the NSSplitView-overrun invariant).
  GUI half: ⌘J (`BuiltinAction.toggleScratch`), title-bar `scratch-toggle` button,
  View ▸ Show/Hide Scratch, the ⌃⇧P palette "Toggle Scratch" — all through `AppActions.toggleScratch()`.
  The scratch surface is NOT OPERATIONALLY wired to the session (still no `view.session`, like the overlay)
  so its PWD/title never clobber the sidebar name — but it DOES carry a SECOND weak link,
  `GhosttySurfaceView.watermarkSession`, holding only the owner's VISUAL config (background watermark +
  font zoom), so the session's `session.background` image/text/color renders on the scratch as well.
  The four watermark read sites take `session ?? watermarkSession`; the overlay and quick-terminal surfaces
  carry NEITHER link and stay a no-op.
  `autoFocus` grabs first responder on show,
  the detail pane's `.onChange(of: scratchActive)` reclaims it on hide.
  Four-point keep-in-sync audit: (1) `case sessionScratch = "session.scratch"` + the new `ControlSessionNode.scratch`
  flag in `ControlProtocol.swift` (reuses `ControlArgs.mode`), (2) the `.sessionScratch` dispatch arm
  (`scratchSession`) in `ControlServer` + `scratch:` in the tree builder,
  (3) the `session scratch` subcommand in `rookctlKit`, (4) round-trip in `ControlProtocolTests` +
  the e2e `testSessionScratchToggle` in `ControlOverlaySplitUITests`.
  `session.focus` moves keyboard focus between the two split panes — `args.pane` is `left`|`right`|`other`
  (`other` toggles, the default); it errors when the session has no split (works whether the split is
  shown side-by-side or hidden — when hidden, focusing a pane swaps which one shows maximized),
  drives `AppActions.setSplitFocus(_:of:)`, and is the control half of the ⌘⌥←/→ keyboard nav + the "Focus
  Left/Right Pane" menu/palette items.
  Its READ side is `ControlSessionNode.splitFocused` (`true`=split/right, `false`=main/left, nil=no split;
  see the `tree` read-side fields below), so a script can record the focused pane and restore it.
  `session.resize` moves the split DIVIDER — it is control-NATIVE (the divider is otherwise mouse-drag
  only; NO GUI/menu/keymap action, so a key is bound by mapping a `command "rookctl session resize …"`
  custom action).
  `args.ratio` sets the absolute left-pane fraction; `args.ratioDelta` is a signed relative nudge (the
  CLI's `--grow-left`/`--grow-right` map to ±`ratioDelta`, applied to the current fraction,
  `AppStore.splitRatioDefault` = 0.5 when never moved); exactly one must be set (neither/both error).
  It errors when the session has no split (mirroring `session.focus`), clamps + persists via the host-free
  `AppStore.applySplitRatio` (→ `AppStore.clampSplitRatio`, `splitRatioMin...splitRatioMax`),
  then posts the object-scoped `.rookApplySplitRatio` (object = the `Session`) so the matching `SplitProbeView`
  (`SplitRatioAccessor.swift`) moves the LIVE divider via `setPosition` — a no-op when the split is hidden (no live
  `NSSplitView`; the stored fraction applies on next show).
  It echoes the applied (clamped) fraction in the new `ControlResult.ratio` (the CLI prints it as a bare
  `%.3f` number, scriptable).
  Four-point keep-in-sync audit for `session.resize`: (1) `case sessionResize = "session.resize"` +
  `ControlArgs.ratio`/`ratioDelta` + `ControlResult.ratio` in `ControlProtocol.swift`,
  (2) the `.sessionResize` dispatch arm (`resizeSplit`) in `ControlServer` (+ the `SplitProbeView` re-apply
  observer in `SplitRatioAccessor`), (3) the `session resize --split-ratio|--grow-left|--grow-right` subcommand
  (`Resize`, `validate()`-guarded exactly-one) in `rookctlKit` + the `result.ratio` format arm in `SocketClient`,
  (4) round-trip in `ControlProtocolTests` + `AppStoreTests` (clamp/apply) + `CommandsTests` (validate/mapping)
  + `SocketClientTests` (format) + the e2e `testSessionResizeSplitDivider` in `ControlOverlaySplitUITests`.
  `session.go` navigates BETWEEN sessions — `args.to` is `next`|`prev`|`first`|`last`|`next-attention`|`prev-attention`
  and acts on the target store's CURRENT selection (it is RELATIVE, so it resolves the placement store
  via `resolvePlacementStore` rather than a session target — there is NO `--target`),
  WRAPS around on next/prev (an end lands on the opposite end, within the filtered set), jumps to the ends for first/last,
  and for `next-attention`/`prev-attention` steps through ONLY the sessions needing attention (`AgentStatus.needsAttention`
  = `blocked`/`completed`) WRAPPING around (skipping idle/active), drives `AppStore.navigateSession`,
  and returns the newly-selected id in `result.id`.
  It mirrors the `session.focus --pane` one-command-with-arg precedent and is the control half of the
  ⌥⌘↑/⌥⌘↓ session-nav + ⌃⌥↑/⌃⌥↓ attention-nav menu/palette items (First/Last have no hotkey).
  `notify` posts a desktop notification attributed to a session (default:
  the active session of the frontmost window via `resolveSession`): `args.body` is required,
  `args.title` defaults to the session name.
  It is control-NATIVE (no GUI/menu equivalent, like `session.type`/`session.copy`) and goes through
  `NotificationManager.send(toSession:title:body:)` — which, unlike the OSC 9/777 path,
  does NOT focus-suppress (the caller asked for it) but still bumps the badge + carries the `<windowID>:<sessionID>:main`
  click-to-reveal identity.
  It is the ONLY app-level way to post a banner; the terminal OSC path remains the other source.
  **With the banner toggle OFF the command still succeeds** (the badge tracks either way) but carries the
  advisory `ControlNotify.bannersOffNote` in `result.text` — `badge updated, but "Show notification banners"
  is off, so no banner was posted` — which `SocketClient` already prints in place of `ok`,
  so there is NO CLI change; the same ok-with-advisory shape as `session.agent`'s
  `ignored: not the pane's agent`.
  The constant lives next to `OverlayResultError` in `rookCore/Sources/rookCore/ControlProtocol.swift`
  and is shared for the same reason: the server's wording and any caller matching on it must not drift.
  `session.new` creates a session.
  The destination workspace is addressed one of two MUTUALLY-EXCLUSIVE ways:
  `args.workspace` (id / unique prefix / `active`, the default) OR `args.workspaceName` (the sidebar
  label, name-matched first-exact-trimmed via `AppStore.workspace(named:)`) — the latter optionally with
  `args.createWorkspace` to reuse-or-create the named workspace (idempotent;
  `AppStore.ensureWorkspace(named:)`).
  A `workspaceName` with no match and no `createWorkspace` errors, both addressing modes set is an error,
  and `createWorkspace` without `workspaceName` is an error (nothing to create by id);
  the same two rules are pre-validated CLI-side by `session new`'s `validate()`.
  `args.after`/`args.before` (a session address — id / prefix / `active`) instead PLACE the new session
  directly after/before an anchor session rather than appending at the end (`ControlSessionCreateOptions.after`/`before`).
  The anchor CARRIES ITS OWN WORKSPACE (resolved across all workspaces), so it names the destination
  itself — after/before is a self-contained placement mode, mutually exclusive with each other and with
  `--workspace`/`--workspace-name` (errors: `"use either --after or --before, not both"` and
  `"session.new takes --after/--before or a workspace, not both"`, dispatcher-owned + CLI-pre-validated).
  The app-side `createSession` resolves the anchor, takes its `(workspace, index)`, and inserts via
  `AppStore.addSession(…, at: before ? index : index + 1)` (the new optional `at index:`, clamped).
  `rookctl session new --after active` = create right after the current session in one round-trip.
  `args.command` runs that command AS the session's process instead of an interactive shell (like kitty's
  `launch <cmd>` / ghostty's `command`) — NO echoed command line, and the session closes when the command
  exits (the normal single-pane `onExit` → `closePrimaryPane`).
  `Session.initialCommand` is `@ObservationIgnored` but PERSISTED via `SessionSnapshot.initialCommand`, so it
  re-runs on restore (through the same `config.command` exec path) when the **restore-running-command** opt-in
  is on — gated via the transient `Session.wasRestored` so a fresh session always runs its command while a
  restored one honors the toggle (default off → a restored session is a plain shell); a live captured
  foreground preempts it, and `closePrimaryPane` clears it when a command pane exits into a promoted split.
  The arm threads `request.args?.command` into `AppStore.addSession(…, command:)`,
  which `makeSurface` hands — together with the session's own `Session.shell` — to the host-free
  `SurfaceCommand.resolve(shell:command:defaultShell:)`,
  whose result becomes `GhosttySurfaceView(command:)` → `config.command`.
  **A `--command` session runs under a LOGIN SHELL: `<shell> -l -c '<cmd>'`** — the session's own `--shell`
  when one was sent, else `GhosttyApp.defaultShell` (`$SHELL` when it passes `isValidShellPath`, else
  `/bin/sh`, because an app launched from the Dock inherits launchd's environment where `SHELL` may not
  exist at all and an empty default would build ` -l -c '<cmd>'`).
  So the user's rc files DO run, `PATH` is the login shell's rather than launchd's, a bare Homebrew binary
  resolves instead of exiting 127, and shell operators (`;`, `&&`, `|`, `$VAR`, redirects, globs) work as
  written — `--command "clear; ssh host"` clears and then connects.
  This is a DELIBERATE behavior change with NO opt-out flag: the old form was a trap documented in three
  places, not a feature.
  **The OVERLAY is deliberately UNCHANGED** — `makeOverlaySurface` still wraps its command in `sh -c '…'`,
  so it gets shell operators but runs NO rc and keeps the app's GUI `PATH` (the launchd default, no
  `/opt/homebrew/bin`): a bare Homebrew binary in `session.overlay.open` still exits 127, the overlay
  flashes open then vanishes, `session.overlay.result` reports 127, and the fix is still an absolute path or
  a LOGIN-shell wrapper (`zsh -lc '…'`).
  Whether the overlay should follow the session is an open question for the maintainer — do NOT harmonize
  the two in passing.
  **The pre-feature note here was WRONG on three counts; do not re-introduce them.**
  It claimed there was NO `sh -c`, that shell operators were NOT interpreted, and that libghostty execs
  argv[0] DIRECTLY.
  Checked against the pinned libghostty source: `src/apprt/embedded.zig` maps the C-API `command` string
  ALWAYS to `.shell` (`config.command = .{ .shell = cmd }`, upstream comment "This command always run in a
  shell"), and `src/termio/Exec.zig`'s `execCommand` routes BOTH command forms through
  `/usr/bin/login -flp <user>` on macOS.
  The real pre-feature spawn was therefore
  `login -flp <user> /bin/bash --noprofile --norc -c 'exec -l <cmd>'` — a shell was always in the picture.
  What WAS true is the consequence: that trampoline bash is `--noprofile --norc` and the command itself
  became the login shell, so no rc ran, `PATH` stayed the launchd default, and a bare Homebrew binary
  exited 127.
  And `clear; ssh …` broke not because operators were ignored but because bash ran `exec -l clear`, which
  REPLACED the shell — nothing after the `;` could ever run.
  That also fixes the tokenization budget for the new form: our string passes through exactly ONE round of
  parsing (that trampoline bash), which is why `SurfaceCommand` single-quotes the command and only quotes a
  shell path that needs it.
  **`args.shell` (`--shell <absolute path>`) makes a spawned session run the CALLER's shell.**
  Three commands carry it — `session.new`, `window.new`, `quick` — and `rookctl` fills it from the caller's
  own `$SHELL` by default (`CallerShellOptions.resolved(env:)`, applied on the SEND path in
  `requestCarryingCallerShell`; an unset or blank `$SHELL` sends NOTHING, so the request stays
  byte-identical to a pre-feature one).
  That is what makes a session created from fish come up fish instead of inheriting whatever shell the APP's
  environment happens to name.
  ONLY the shell path travels — never the caller's environment: it carries `ROOK_SESSION_ID`/`ROOK_PANE` and
  the agent's session ids, so inheriting it would make the new session report its agent status onto the OLD
  session's row.
  The login shell rebuilds everything else from its own rc files.
  **Routing: `session.duplicate`, `session.split` and `session.scratch` take NO `--shell`** — they inherit
  from the OWNING (or source) session, because half a session in a different shell is exactly the invisible
  divergence the feature closes.
  Validation splits like `session.background`'s: the DISPATCHER owns the host-free format check
  (`SurfaceCommand.isValidShellPath` — absolute path, no control characters) in ONE shared `parseShell`
  helper used by all three arms (`dispatchSessionCommand`/`dispatchWindowCommand`/`dispatchAppCommand`, so
  three copies can't drift apart on the error text), error `invalid shell (expected an absolute path)`;
  the app side owns the filesystem leg (`ControlServer+Shell.rejectUnusableShell` — exists, not a directory,
  executable), error `shell not found or not executable: <path>`.
  Both reject BEFORE anything is created, so a rejected shell leaves the state untouched.
  **Over the wire it is LOUD, from a snapshot it is SILENT — the asymmetry is deliberate.**
  `SurfaceCommand.resolve` degrades a malformed shell to the default without a word, because a restored
  `workspaces.json` reaches it PAST the dispatcher and nobody is left to repair the value: opening a working
  session on the default shell beats refusing to start.
  A caller who just mistyped, by contrast, has to hear about it.
  `SurfaceEnvironment` exports `SHELL=<path>` for a session running a shell of its own, gated on the same
  `isValidShellPath`, since `login -flp` would otherwise leave the passwd shell in `SHELL` and every
  subprocess would believe the wrong one.
  READ-BACK: `Session.shell` (`@ObservationIgnored`) persists via `SessionSnapshot.shell` (an Optional field,
  NO `Snapshot` version bump — the `WorkspaceSnapshot.colorHex` precedent) and reads back on
  `ControlSessionNode.shell`, omitted when the session is on the app default, so a fish session comes back
  fish after a relaunch instead of silently reverting.
  The decode is LOSSY on purpose: a wrong-typed value falls to nil rather than throwing the whole workspace
  file out over one bad field, and a hostile but well-typed string is kept and degrades later at spawn, where
  `resolve` already handles it.
  **Known limitation, documented rather than fixed: a login shell whose rc does a `cd` overrides the
  session's starting directory** — `--cwd` is where the shell starts, not necessarily where it lands.
  The shell must also understand `-l -c`; zsh, bash and fish do.
  Keep-in-sync: the `.sessionNew` case carries `ControlArgs.command` plus `ControlArgs.name` (custom
  name) and `ControlArgs.workspaceName` + `ControlArgs.createWorkspace` (name-addressing + ensure);
  the arm pre-validates the mutual-exclusion / create-needs-name rules and shares `makeSessionResponse`
  across the id- and name-addressed paths; the `session new` CLI carries `--command`/`--name`/`--workspace-name`/`--create-workspace`
  (the last two also `validate()`-guarded); and round-trip + e2e (`testSessionNewWithCommandRunsAsProcess`,
  `testSessionNewWithName`, `testSessionNewWorkspaceNameCreatesThenReuses`) cover them.
  `ControlArgs.shell` rides the SAME `.sessionNew` case (an argument, NOT a new `Command` — the catalog
  count does not move), with the `--shell` option shared by `session new`/`window new`/`quick` via
  `CallerShellOptions`, and `SurfaceCommandTests` + `ShellInheritanceCommandsTests` +
  `ControlProtocolTests`/`PersistenceTests` (round-trip, omit-when-nil, legacy snapshot with no key)
  covering the build, the CLI default and the read-back.
  `session.new` ALSO takes `--no-select` and `--wait` (ports of upstream bdc3684 + 8220978 — NO new
  `Command` case for the flags — the catalog bump to 66 is `session.duplicate` below).
  `ControlArgs.noSelect` + `ControlSessionCreateOptions.noSelect` create the session in the BACKGROUND:
  `AppStore.addSession` gained a defaulted `select: Bool = true` gating `selectedSessionID` /
  `disableFocusIfSelectionOutsideSet` / `recordRecency`, `makeSessionResponse` passes `select: !noSelect`
  and skips the focus call, and the `--create-workspace` path threads `revealNewWorkspace: !noSelect` so a
  background create can't widen the marked workspace set; read-back is the existing `tree` `active` flag (a
  background session is not `active`) — state-mutating-read-back EXEMPT, no new field.
  Both names changed with the focus SET (the parameter also inverted its mechanism — it no longer CLEARS a
  focus, it declines to JOIN the set); see the `workspace.focus`/`workspace.filter` section.
  `ControlArgs.wait` + `ControlSessionCreateOptions.wait` HOLD a `--command` session open on libghostty's
  press-any-key prompt after the command exits: `rookApp.makeSurface` threads `session.commandWait` into
  the existing `GhosttySurfaceView` `waitAfterCommand` param (the same one the overlay factory uses via
  `overlayWait`), it persists via `Session.commandWait` (`@ObservationIgnored`) + `SessionSnapshot.commandWait`
  (`false`→nil write, nil→`false` restore), `closePrimaryPane` clears it alongside `initialCommand` on split
  promotion, `--wait` without `--command` is rejected in BOTH the dispatcher AND the CLI `validate()`, and
  its read-back is the new `ControlSessionNode.commandWait` (gated `initialCommand != nil && commandWait`).
  `session.duplicate` (target = the source session) duplicates it into a FRESH shell rooted at the source's
  focused-pane cwd (`Session.focusedCwd`), inserted directly AFTER it in the same workspace via the host-free
  `AppStore.duplicateSession` → `addSession(toWorkspace:cwd:at:shell:)`; only the directory AND the source's
  `shell` carry over (no command/name/split/scratch — a plain shell, but the SAME shell: coming up in a
  different one is exactly the divergence `--shell` exists to close, and an invisible one).
  A source on the app default duplicates as nil rather than resolving eagerly, so the copy does not freeze
  today's default into its own persisted state.
  It is a NEW `Command` case (catalog 65 → 66).
  Five callers share the one `AppStore.duplicateSession` seam: the control arm (`ControlActions.duplicateSession`,
  which focuses only when the target store is the active one, like `session.new`), and — via
  `AppActions.duplicateSession(_:in:)` / `duplicateActiveSession()` (`AppActions+Duplicate.swift`) — the
  sidebar row context menu, the menu bar, the ⌃⇧P palette, and the keyless `BuiltinAction.duplicateSession`
  keymap action.
  READ-BACK is the returned `result.id` (a create command — no new tree field, state-mutating-read-back
  EXEMPT).
  Four-point audit: `case sessionDuplicate` in `ControlProtocol`, the `.sessionDuplicate` dispatcher arm +
  `ControlActions.duplicateSession`, the `rookctl session duplicate` subcommand, and round-trip +
  dispatcher + CLI + `AppStoreDuplicateTests` (e2e in `ControlAPIUITests` — deferred, XCUITest).
  `session.type` injects into the target surface.
  `args.pane` picks the pane like `session.text` (`left`|`right`|`scratch`, no `other`):
  omitted/`left` is the MAIN pane (omitted deliberately keeps the pre-pane behavior — always the main
  pane, NOT the focused/on-screen one, so existing automation is unaffected);
  `right` injects into the split surface, `session has no split pane` without one;
  `scratch` injects into the session's scratch terminal, typable even while HIDDEN (its surface is kept
  alive), `session has no scratch terminal` when none has been opened;
  and an unknown value is an `invalid pane` error — all validated SERVER-SIDE in `injectText`
  (mirroring the CLI `validate()`), so a raw socket client can't bypass it.
  Every session is realized eagerly (the deck mounts all at startup), so any session is normally typable
  WITHOUT `select`; `select:true` remains for the brief window before a just-created session is mounted
  (select, then a bounded poll, the `focusSplitPane` idiom), with `session not realized` the fallback
  if the surface still isn't up.
  The realize/select path applies to the MAIN pane only — a split pane is never created by selecting,
  so `pane:right`/`pane:scratch` inject into the existing surface or error.
  **`session.type` also BROADCASTS**: a repeated `--target` (`args.targets`, more than one) or `--flagged`
  types the SAME text into many sessions in one call, which is what a flock of agents actually needs (the
  loop used to live outside, in the caller's shell).
  The two selectors are mutually EXCLUSIVE and the conflict is an ERROR, not a silent drop
  (`session.type takes --flagged or --target, not both`) — unlike `session.flag clear`, whose `--target`
  is meaningless anyway; here a target LOOKS honored, so losing it quietly would be a lie.
  `--select` is single-target by nature (it selects one session to realize its surface), so it is rejected
  for a broadcast (`session.type --select works with a single target only`).
  Both strings are pinned at BOTH levels — the CLI `validate()` and the dispatcher — like `session.move`'s,
  so the same mistake reads identically from `rookctl` and from a raw socket client.
  The `select` check tests for an explicit `true`, NOT for presence: the CLI always sends the field
  (`select: false`), so a `!= nil` check would reject every CLI broadcast.
  `flagged` conversely rides as nil when the flag is absent, never `false`, so a single `session.type`
  request stays BYTE-IDENTICAL to its pre-broadcast wire form.
  **Resolution is all-or-nothing; the INJECTION is best-effort.**
  The set resolves through the same `resolveBatchSessions` as `session.close`/`session.move` (dedup,
  one-window scoping, any unknown/ambiguous target fails the whole request before a single shell sees the
  text); `--flagged` instead resolves the store by `--window`/frontmost and takes `store.flaggedSessions`,
  keeping the batch's one-window scope.
  Injection then runs `injectText` per session and reports `result.affected` — and when some session could
  not take it (`session not realized`, `session has no split pane`) the reply is `ok: false` WITH that
  count plus the first failure's error.
  A partial failure must NOT report `ok: true` and must NOT drop the count: the text has already landed in
  the other shells and an injection cannot be taken back, so the reply has to be truthful in both
  directions.
  **That truth has to reach the HUMAN output too, which is why `SocketClient.formatResponse` now appends
  the count to a non-ok line** (`error: session not realized (3 sessions affected)`).
  It used to return early on `!ok` and throw `result` away, so the count lived only under `--json`: the user
  read a bare `error:`, concluded nothing happened, re-ran the broadcast, and the sessions that already took
  the text got it TWICE.
  The fix belongs in `formatResponse`, NOT in one command's error string — the next batch command inherits it
  instead of re-discovering the trap.
  It changes no existing command's output because the "non-ok WITH `affected`" shape did not exist before
  this feature (batch `close`/`move` always answer `ok: true`), and a non-ok response WITHOUT a count stays
  byte-identical.
  The count phrase itself is the shared `affectedPhrase` helper, so the success line (`3 sessions`) and the
  failure suffix cannot drift apart.
  **The empty-set asymmetry is deliberate.**
  An empty FLAGGED set is `ok` with `affected: 0` (the caller asked for "every flagged session" and there
  are honestly none, matching batch `move`/`close`), while an explicitly EMPTY `targets` array is an ERROR
  (`session.type requires at least one --target`).
  Measured on RED: an empty/flagged-less request fell through to `typeSession(target: "active")` and TYPED
  THE TEXT INTO THE ACTIVE SESSION, which the caller never named — the worst outcome for an input command.
  The CLI never sends it (`batchTargets` is nil below two targets), so the guard is dispatcher-ONLY — there
  is no CLI-side twin to keep in step, because the CLI cannot produce the request at all.
  The guard fires with ZERO calls into `ControlActions`: for an input command "reject after resolving" is
  already too late, since the resolve step is what lands on `active`.
  **Do NOT collapse the two empty cases into one branch** — they are the same shape on the wire and opposite
  in meaning: an empty `targets` array is a MALFORMED call, an empty flagged set is a WELL-FORMED call whose
  honest answer is zero.
  A one-element `targets` array routes to the singular path, like the batch `session.close`/`session.move`.
  `--pane` applies to every target with one value (validated server-side in `injectText`, as before).
  The command CATALOG does NOT grow — these are flags on an existing command, so no count surface moved for
  them (the catalog total has since risen for unrelated reasons; the point here is that flags never move it).
  **No new `tree` read-back is owed**: `session.type` mutates no app state (the text goes into a shell), and
  its read leg is the existing `session.text`.
  Keep-in-sync: `ControlArgs.flagged` in `ControlProtocol.swift`, the `.sessionType` arm
  (`ControlDispatcher.dispatchSessionType`, which owns both conflicts + the empty-array guard + the
  single/broadcast routing), `ControlActions.typeSessions` implemented in
  `ControlServer+SessionActions.swift`, `rookctl session type`'s `BatchTargetOptions` + `--flagged` +
  `validate()`, and round-trip / dispatcher / CLI tests plus the `SessionTypeBroadcastUITests` e2e.
  Four-point keep-in-sync audit for `session.type --pane`: (1) reuses `ControlArgs.pane` in
  `ControlProtocol.swift` (no new field), (2) the pane switch in `injectText`
  (`ControlServer+SurfaceIO.swift`), (3) the `session type --pane left|right|scratch` option
  (`validate()`-guarded) in `rookctlKit`, (4) round-trip in `ControlProtocolTests` + CLI mapping in
  `CommandsTests` + the e2e (`testSessionTypePaneRightReachesSplitPane`,
  `testSessionTypePaneRightWithoutSplitErrors`, `testSessionTypeRejectsInvalidPaneServerSide`) in
  `SessionTypePaneUITests` (a `ControlAPITestCase` subclass like `SessionTextUITests`).
  `GhosttySurfaceView.inject(text:)` types via `ghostty_surface_key` keystrokes (printable runs as key-with-`text`,
  each `\n`/`\r`/`\r\n` as a Return keypress, keycode 36) — NOT `ghostty_surface_text`,
  whose bracketed-paste wrapping suppresses Enter and leaks `\e[200~`/`\e[201~` markers when fired rapidly.
  Do not "simplify" it back to `ghostty_surface_text`.
  `session.copy` reads the target surface's selection via `GhosttySurfaceView.readSelection()` (`ghostty_surface_has_selection`
  + `ghostty_surface_read_selection`, freed with `ghostty_surface_free_text`) and returns it in `result.text`
  — it does NOT touch the system clipboard (automation pipes the returned text into another `session.type`);
  selection is surface state independent of focus, so any realized session can be read,
  and no/empty selection is a `no selection` error.
  `session.paste` pastes the SYSTEM clipboard (`NSPasteboard.general`) into the target session's MAIN
  surface — the socket analogue of ⌘V / Edit ▸ Paste.
  `session.selectall` selects the target's ENTIRE terminal buffer (main surface) — the analogue of ⌘A /
  Edit ▸ Select All.
  Both run a libghostty binding action on the resolved surface — `paste_from_clipboard` /
  `select_all` — through the shared `ControlServer+SurfaceIO.surfaceBindingAction` helper
  (resolve session → guard the surface is realized, `session not realized` otherwise → `performBindingAction`
  → return the id), so paste takes the normal libghostty paste path (bracketed paste, PASTE requests are
  ungated so no OSC-52 prompt) and select_all covers the whole grid.
  They are the control half of the GUI Edit menu: rook keeps the STANDARD SwiftUI Edit menu and
  implements `copy:`/`paste:`/`selectAll:` + `validateMenuItem:` on `GhosttySurfaceView` (`+Input.swift`,
  conforming to `NSMenuItemValidation`) so AppKit's automatic menu enabling routes Copy/Paste/Select All
  to the terminal when it holds first responder — Copy enabled on `ghostty_surface_has_selection`, Paste
  on `GhosttyCallbacks.hasPasteboardText()`, Select All on a realized surface (all three also require
  the surface, since `performBindingAction` no-ops without one) — while a focused text field (rename/palette/Settings)
  keeps its own editing (its field editor wins the responder chain), and Cut stays disabled for the terminal
  (deliberately NOT implemented) yet works in text fields.
  **Cut cannot be dropped on its own** — SwiftUI puts Cut/Copy/Paste/Delete/Select All in ONE `.pasteboard`
  `CommandGroup`, and replacing that group is what would take ⌘C/⌘V/⌘A away from the rename/palette/Settings
  fields.
  **Undo/Redo ARE dropped** (`CommandGroup(replacing: .undoRedo) {}` in `rookApp+Menus.swift`): they are
  their own group, rook registers no `NSUndoManager`, and their advertised ⌘Z is already owned by File ▸
  Reopen Closed Item (`BuiltinAction.undoClose`), whose menu precedes Edit and wins the key-equivalent search —
  so Edit ▸ Undo could only ever be CLICKED, never invoked by its own shortcut.
  AppKit did enable it for the sidebar's inline rename field (whose field editor supplies an undo manager),
  but a permanently-greyed item that duplicates another menu's shortcut for one narrow case is worse than no
  item; `EditMenuUITests.testEditMenuHasNoUndoOrRedoItems` asserts NON-EXISTENCE (an `isEnabled == false`
  check would pass vacuously on a missing element).
  **Paste MUST validate with the same branches the paste path reads**, and must agree with it in BOTH
  directions.
  Two ways to get this wrong, both found in review:
  a `canReadObject([NSString])` probe greys the item out for a Finder file copy (a file URL with NO string
  representation, which `pasteboardText` turns into a shell-escaped path) while ⌘V pastes the path anyway;
  and a `canReadObject([NSURL])` probe is a TYPE check, so a pasteboard merely DECLARING `public.file-url`
  with no usable value enables Paste while the reader returns nil and the paste inserts nothing.
  Either direction reintroduces the menu-vs-keyboard divergence these responders exist to remove.
  So `hasPasteboardText` runs the reader's own URL branch, short-circuiting on the first usable URL
  (`contains(where:)`) instead of mapping/escaping/joining the whole clipboard — validation fires on every
  menu open and every ⌘V key-equivalent lookup, so it must not materialize a Finder copy of thousands of files.
  Both share the single `urlText` helper so they cannot drift.
  **Keep the predicate and the reader in step; this invariant has NO automated test** (verified instead with a
  named-pasteboard probe across the empty / plain-text / empty-string / whitespace / file-url / web-url /
  multi-url / declared-without-data shapes).
  The file-URL case is NOT XCUITest-able: the runner is sandboxed (`com.apple.security.app-sandbox`), so a file
  URL it writes to `NSPasteboard.general` never becomes visible to the app — instrumenting `hasPasteboardText`
  showed the app reading `types=[]` for a full 8 s poll while the runner's own `canReadObject([NSURL])` returned
  true from its in-process cache.
  Such a test exercises the sandbox, not `validateMenuItem`, so it was removed rather than left red (verified
  instead with a cross-process probe outside the runner).
  Do not re-add it as an XCUITest.
  The app-target `bundle.unit-test` this note used to say we lacked now EXISTS (`rookTests`), and it is the
  right home: it runs in-process, so it can exercise `hasPasteboardText` against a NAMED pasteboard without
  the runner's sandbox in the way — which is exactly what defeated the XCUITest version.
  A `NSPasteboard.general` read in the app also LAGS a writer process's `changeCount`, so any UI test that seeds
  the clipboard must POLL rather than read once.
  ⌘C/⌘V/⌘A therefore route through the Edit menu (fixed standard shortcuts, NOT rebindable — the maintainer's
  call); the `ghostty-defaults.conf` `super+key_c`/`super+key_v`/`super+key_a` binds stay as a non-Latin-layout
  backup.
  The mechanism is that AppKit matches a menu key equivalent against the character the layout PRODUCES: on a
  Cyrillic layout ⌘C yields `с`, no equivalent matches, the event reaches `keyDown` and the keycode-triggered
  `super+key_c` fires. (A DISABLED item likewise doesn't consume its equivalent, so ⌘C with no selection also
  falls through.) There is no AppKit "Latin fallback" doing this — the binds are load-bearing, not dead code.
  **`super+key_a=select_all` is one of them**: without it ⌘A silently does nothing on a Cyrillic/Greek layout,
  since libghostty's built-in `super+a` is character-matched too (found in review — the fallback set must cover
  every shortcut the Edit menu owns, not just copy/paste).
  **The session-scoped surface arms resolve `Session.addressableSurface`, not `Session.surface`.**
  `session.copy`/`session.paste`/`session.selectall` act on "the session" rather than a named `--pane`
  (and so does `font.*`'s omitted/`left` default — its `right`/`scratch` panes resolve `splitSurface`/`scratchSurface`
  instead, via its own pane switch rather than `surfaceBindingAction`),
  and `addressableSurface` is `surface ?? splitSurface`: identical to `surface` for every ordinary or split
  session — INCLUDING a promoted split survivor, which `closePrimaryPane` now MOVES into `surface` (nilling
  `splitSurface`), so the `?? splitSurface` term is a DEFENSIVE fallback rather than the promotion path it
  was written for (asserted by `AppStorePaneTests`).
  **A promoted survivor is the MAIN/left pane, everywhere.** Its primary shell exited, the split pane took
  over the main slot, and `tree` reports `split:false`, so `session.type`/`session.text` with no `--pane`
  (or `--pane left`) reach it, `--pane right` errors "session has no split pane", `session.focus` errors,
  `{AGT_PANE}` reports `left`, and a later `session.split` opens a FRESH right pane beside it.
  This SUPERSEDES the old contract, where the survivor stayed parked in `splitSurface` and was reachable
  only as `--pane right` while `tree` already said `split:false` — a self-contradiction under which a plain
  `session.type` (no `--pane`) returned `session not realized` for a session the user was actively typing in.
  Scripts written against the old contract (addressing a collapsed session as `--pane right`) must switch to
  the default/left addressing.
  The survivor's agent-status tag migrates with it: a `.right` block is re-tagged `.left` at promotion, and
  `AppStore.setAgentIndicator` COERCES a `.right` tag to `.left` on any session with `!hasSplit` (the
  promoted shell keeps its baked `ROOK_PANE=right`, so its hook keeps sending `--pane right`) — gated on
  `hasSplit`, NOT `splitSurface == nil`, so a scripted `session.split` + immediate `session.status --pane
  right` inside the surface-realization window keeps the correct forward `.right` tag.
  The coercion is now the FALLBACK layer: the hook also forwards the surface's stable `ROOK_PANE_ID` as
  `session.status --pane-id`, which resolves the pane's CURRENT slot and overrides the stale role — see the
  `session.status` section, which is also where the coercion's remaining job (a promote + re-split, where
  both shells were baked `right`) is spelled out.
  It is deliberately NOT focus-aware (unlike `activeSurface`) — a shown split keeps addressing the main
  pane, which is what keeps `session.selectall` and its `session.copy` read-back on the SAME surface.
  READ-BACK: neither adds a `ControlSessionNode` field — `session.selectall`'s read-back is `session.copy`
  (reads the resulting selection) and `session.paste`'s is `session.text` (reads the inserted buffer), the
  sibling-command pattern (like `quick.type`↔`quick.text`).
  Four-point keep-in-sync audit: (1) `case sessionPaste = "session.paste"` + `case sessionSelectAll = "session.selectall"`
  in `ControlProtocol.swift` (no new args/fields), (2) the `.sessionPaste`/`.sessionSelectAll` arms in
  `ControlDispatcher.dispatchSessionSurfaceCommand` → `ControlActions.pasteSession`/`selectAllSession`
  (app-side `ControlServer+SurfaceIO`), (3) the `session paste` / `session select-all` subcommands in
  `rookctlKit`, (4) round-trip in `ControlProtocolTests` + dispatcher routing in `ControlDispatcherTests`
  + CLI mapping in `CommandsTests` + the e2e `testSessionSelectAllThenCopyReturnsBuffer` /
  `testSessionPasteInsertsClipboardText` in `ControlAPIUITests`.
  `session.text` reads the target surface's screen buffer as PLAIN TEXT (no ANSI) via `GhosttySurfaceView.readScreenText(all:lines:)`
  (a `ghostty_selection_s` spanning VIEWPORT top-left→bottom-right by default,
  SCREEN when `args.all || args.lines != nil`, `rectangle = false`;
  `ghostty_surface_read_text` → copy out of `ghostty_text_s` → `ghostty_surface_free_text`) and returns it in `result.text`
  — `args.all` adds scrollback, `args.lines N` keeps the last N CONTENT lines (trailing blank grid rows
  trimmed so a non-scrolled screen returns content, not padding), and `args.pane` (`left`→main,
  `right`→split-else-`session has no split` error, `scratch`→the scratch terminal's surface, readable even
  while HIDDEN since it is kept alive (`session has no scratch terminal` when none opened),
  omitted→the ON-SCREEN surface via the shared `Session.onScreenSurface` (scratch-when-covering else the
  focused pane, the SAME resolution `session.search` uses), so a no-`pane` read returns what's visible,
  not a pane hidden under the scratch) picks the pane.
  `args.all`+`args.lines` are mutually exclusive and `args.lines` must be > 0 — validated SERVER-SIDE in
  the dispatcher (`ControlDispatcher.dispatchSessionText`, mirroring the CLI `validate()`), NOT only CLI-side, so a raw socket client can't bypass it
  (an unchecked `lines ≤ 0` would otherwise fall through to the full buffer).
  UNLIKE `session.focus`, the `pane` here is `left|right|scratch` (no `other`).
  A genuinely BLANK screen reads `ok` with an empty string (NOT an error, on purpose — differs from `session.copy`'s
  `no selection`), but a FAILED `ghostty_surface_read_text` is a `failed to read surface buffer` error:
  `readScreenText` returns `""` for the empty read and nil ONLY for a real failure, which the app-side `readSessionText` maps
  to the error (so a caller can tell a blank terminal from a broken read).
  An UNREALIZED pane answers `session not realized`, not `failed to read surface buffer`, whether its slot
  is empty or holds a view whose libghostty surface never came up — one state to a caller, and the reading
  never happened.
  `readSessionText` therefore checks `GhosttySurfaceView.isRealized` BEFORE reading, leaving the genuine
  read-failure path alone; that unrealized state is exactly what a display-asleep create leaves behind (see
  [[libghostty]] and the `realized` tree field below).
  `quick.text` keeps its own four-state vocabulary and still reports `failed to read surface buffer` for an
  unrealized quick surface.
  Plain text only — the pinned libghostty exposes only `ghostty_surface_read_text` (no per-cell SGR),
  so `--ansi` is out of scope until a styled surface read lands upstream and the pin is bumped.
  Four-point keep-in-sync audit for `session.text`: (1) `case sessionText = "session.text"` + new `ControlArgs.all: Bool?`/`lines: Int?`
  (reuses `pane` + `ControlResult.text`) in `ControlProtocol.swift`, (2) the `.sessionText` dispatcher arm —
  `ControlDispatcher.dispatchSessionText` (validation + response shape) with the app-side `readSessionText` (the surface read) behind `ControlActions`,
  (3) the `session text [--all] [--lines N] [--pane left|right|scratch]` subcommand in `rookctlKit`
  (`validate()` guards the flag combos, re-enforced SERVER-SIDE in the dispatcher), (4) round-trip tests in
  `ControlProtocolTests` + the e2e (`testSessionTextReturnsBuffer`, `testSessionTextSplitPaneWithoutSplitErrors`,
  `testSessionTextRejectsInvalidArgsServerSide`, `testSessionTextBlankScreenReturnsOkEmpty`) in `SessionTextUITests`
  (a `ControlAPITestCase` subclass in its own file, sharing the harness base with the `Control*UITests` suites).
  `session.search` searches the target session's live scrollback (target = session) — it SELECTS the
  target (so the bar + match highlights render and the surface is realized,
  bounded-realize-polled like `session.type`), then drives the FOCUSED surface over `ghostty_surface_binding_action`:
  `args.text` is the needle (`sendSearchQuery`, opening search first via `startSearch` if not already
  `searchActive`), `args.to` is `next`|`prev`|`close` (`navigateSearch(.next/.previous)`;
  `close` → `endSearch()` returns ok with no counter).
  The match count lands ASYNC via libghostty's `SEARCH_TOTAL` callback, so the arm bounded-polls `session.searchTotal`
  (the overlay-result idiom) before returning `result.count` = total matches + `result.text` = the "N
  of M" / "M matches" / "no matches" display string (`Session.searchDisplayText`,
  host-free; an empty display maps to nil `text` so the CLI prints `ok`).
  No needle + no `to` opens the empty bar.
  The four search state fields (`searchActive`/`searchNeedle`/`searchTotal`/`searchSelected`) are ephemeral
  on `Session`, absent from `SessionSnapshot`; the GUI bar (see the Menu/actions + ContentView placement
  notes) and the control channel read/write the SAME fields so they can't drift.
  Four-point keep-in-sync audit for `session.search`: (1) `case sessionSearch = "session.search"` in
  `ControlProtocol.swift` (reuses `ControlArgs.text` = needle + `ControlArgs.to` = next|prev|close,
  and `ControlResult.count` + `text` — no new field), (2) the `.sessionSearch` dispatch arm (`searchSession`)
  in `ControlServer`, (3) the `session search [needle] --next|--prev|--close` subcommand in `rookctlKit`
  (`validate()` rejects flag combos), (4) round-trip tests in `ControlProtocolTests` + the e2e `testSessionSearch`
  in `ControlAPIUITests`.
  `session.overlay.open`/`session.overlay.close` run an ephemeral terminal on top of a session executing
  one program (`args.command`, e.g. a TUI); by default it is full single-pane size,
  hiding the single/split underneath, but `args.sizePercent` (1–100, clamped in `openOverlay`) makes
  it a *floating* opaque framed panel at that percent of the pane with the session still visible.
  `args.color` (`#rrggbb`, REUSING the `session.background` field — no new arg — validated by the shared
  `WatermarkConfig.isValidColorHex` at BOTH the CLI `validate()` and the server arm) gives the overlay
  pane its OWN solid background color, independent of the session's `session.background color`;
  the overlay is sessionless, so it is applied to the overlay SURFACE (not via the session) as the SAME
  `.color` per-surface config overlay (`WatermarkConfig.overlayText` → `configWithOverlay`,
  honoring window translucency), built in `GhosttySurfaceView.applyOverlayBackgroundColor` from the
  view's `overlayBackgroundColorHex` in `createSurface` — works identically for the full + floating variants.
  `AppStore.openOverlay`/`closeOverlay` set non-persisted `Session.overlay*` state (incl.
  `overlaySizePercent`, nil = full / non-nil = floating; and `overlayBackgroundColor`,
  set at open / cleared at close), and the surface runs `config.command` with
  `onExit → closeOverlay`.
  Both variants render IN the per-session eager deck, so the overlay program runs regardless of which
  session is active — the only visible difference is geometry.
  The overlay is ONE always-present, CONSTANT-SHAPE ZStack sibling in `WindowContentView.sessionDetail`,
  `overlayPanel(session:isActive:)` at `.zIndex(3)`, hosting BOTH variants from a single surface host (the
  pre-unify split — a `fullOverlay`-gated `.zIndex(2)` sibling PLUS a separate `floatingOverlayPanel` at
  `.zIndex(3)` — is GONE; `session.overlay.resize` below is why one host matters).
  The panel content (the overlay surface; the opaque `terminalColor` backing + hairline frame + shadow; the
  click-catcher) is gated INSIDE the always-present `GeometryReader` on `session.overlayActive`, so the
  ZStack child COUNT stays constant across open/close/resize — the same SHAPE as no-overlay, which is what
  keeps the AppKit `NSSplitView` from re-hosting and overrunning UP into the transparent titlebar.
  (The panel used to mount OUTSIDE `sessionDetail` as a `detailPane` `.overlay` for exactly this reason;
  the always-present constant-shape sibling holds the same invariant IN-deck.)
  FULL (`overlaySizePercent` nil): fraction 1.0, drawn translucent + blurred with NO opaque backing and NO
  chrome (`Color.clear` backing, 0 corner radius, 0 shadow), and the pane(s) behind hidden at `.opacity(0)`
  + `.allowsHitTesting(false)` via `hideForOverlay` (= `fullOverlay || scratchActive`; kept MOUNTED, shells
  alive like the deck's inactive sessions), so its transparency reveals the window backing (desktop, tint +
  blur), not the session.
  FLOATING (`overlaySizePercent` set): fraction = `percent/100`, drawn as an opaque `terminalColor`-backed,
  hairline-framed, shadowed panel centered in the detail area with the pane(s) VISIBLE around it.
  The modifier CHAIN is IDENTICAL across both variants — only the parameter VALUES flip (backing color,
  corner radius, shadow radius, frame fraction) — so `session.overlay.resize` switching full<->% is a
  value-update, never a child add/remove or a re-parent of the overlay surface NSView (a re-parent would
  blank its Metal drawable).
  Hit-testing on the PANES stays gated on `.allowsHitTesting(!hideForOverlay)` and must NOT flip when a
  FLOATING overlay opens: changing the panes' OWN `allowsHitTesting` on overlay-open (e.g. to
  `!session.overlayActive`) ALSO triggers the NSSplitView titlebar-overrun — the SAME class of perturbation
  as changing the ZStack's shape, even though it looks like a pure interaction change (Codex insisted
  hit-testing was layout-inert; a review-loop regression proved otherwise).
  So a floating overlay leaves the panes hit-testable, and the overlay's focus is protected by a transparent
  `Color.clear.contentShape(Rectangle())` catcher INSIDE `overlayPanel` that absorbs clicks AROUND the panel
  so they can't reach the panes and steal the overlay program's first responder.
  (Generalize the rule: ANYTHING in `sessionDetail`'s HSplitView-hosting subtree that CHANGES SHAPE when
  `overlayActive` flips — adding/removing a sibling, a flattened ZStack, or a toggled pane modifier —
  overruns the split into the titlebar; keep the subtree's shape identical across open/close/resize and gate
  the panel content INSIDE the constant-shape sibling.)
  This constant-shape invariant is load-bearing: a CONDITIONAL sibling inside `sessionDetail`'s ZStack (the
  HSplitView-hosting subtree) made SwiftUI re-host it and the `NSSplitView` overrun UP into the
  transparent titlebar, painting the split over the header (Codex-confirmed;
  the quick terminal renders at this level for the same reason and never hit it).
  `overlayPanel`'s `GeometryReader` reports the detail area EXACTLY — no manual sidebar/titlebar insets
  (computing those at the window level mis-centered the panel one line low) — so it sizes the floating panel
  to `sizePercent`% and centers it in the detail area, the pane(s) visible around it.
  `isActive` gates the overlay surface's focus, so a background floating overlay RUNS but does not steal
  focus (mirrors the full overlay).
  Because both kinds mount in the eager deck, `ControlServer` does NOT select on open by default; it SELECTS
  the target ONLY when the caller passes `--follow` (gated on `options.follow`, NOT on `sizePercent`) — the
  user-facing "pull me to the overlay" switch.
  Without `--follow` full and floating both open on `--target` and run in the background; a `--block` open
  completes without changing the active session.
  `follow` is a new optional ARG on the existing `overlay.open` command (NO new `Command` case): threaded
  `ControlProtocol` (`ControlArgs.follow`) → `ControlDispatcher` `.sessionOverlayOpen`
  (`ControlSessionOverlayOpenOptions.follow`) → `ControlServer` → the `rookctl … --follow` flag,
  omitted = false for back-compat.
  On close an `.onChange(of: session.overlayActive)` drives `focusAfterReparent()` on the session's `activeSurface`
  so first responder returns to the underlying terminal — the pane re-activating only does a single `makeFirstResponder`,
  which loses the teardown/re-host race (same reason the open path needs the `autoFocus` retry).
  Two libghostty gotchas (confirmed against cmux/macterm, see the gotchas section):
  the surface must **handle `GHOSTTY_ACTION_SHOW_CHILD_EXITED`** (in `GhosttyCallbacks.action`) and return
  `true` to suppress ghostty's "Process exited.
  Press any key" prompt and close immediately — `config.wait_after_command` does NOT suppress it;
  and the overlay must grab focus via a **bounded run-loop `makeFirstResponder` retry** (`autoFocus`),
  since a single-shot loses the SwiftUI/AppKit responder race.
  `--wait`/`overlayWait` keeps the prompt (returns `false` from the action so `close_surface_cb` closes
  after a keypress).
  `handleProcessExit` is idempotent (both the action and `close_surface_cb` can fire).
  Both variants mount in the eager deck, so the caller does NOT need to select the target; `--follow`
  selects it only when the user should be pulled to the overlay.
  **Exit-status capture (`session.overlay.result` + `rookctl … --block`).** `makeOverlaySurface` wraps
  the command in a FIXED `sh -c '( eval "$ROOK_OVL_CMD" ); echo $? > "$ROOK_OVL_CODE"'` — the real
  command + a per-surface temp path ride in env (`ROOK_OVL_CMD`/`ROOK_OVL_CODE`,
  never interpolated), and crucially there is **NO stdout/stderr redirect** so a TUI renders normally;
  only the exit status is captured.
  (libghostty's `GHOSTTY_ACTION_SHOW_CHILD_EXITED.exit_code` reflects the login-shell wrapper — always
  0 — so the status is taken from the wrapper's `echo $?`, NOT libghostty;
  the subshell makes an inline `exit N` propagate.) the surface's teardown reads the temp file → `AppStore.recordOverlayExit`
  (sets the non-persisted `Session.overlayExitCode`) → then deletes it, all in `GhosttySurfaceView.destroySurface`
  (via `onExitCodeCaptured`), so EVERY in-process close path — natural exit,
  explicit `session.overlay.close`, force-close (session/workspace/window) — captures the status before
  the file is removed, and the file's lifetime tracks the surface (no registry/sweep);
  `onExit` itself just drives `closeOverlay`.
  `session.overlay.result` (target = session) returns `result.exitCode` once the overlay has closed (`OverlayResultError.stillRunning`
  while up, `noResult` if none ran — both shared constants so the CLI poll matches exactly).
  `rookctl session overlay open <command> … --block` wraps open → poll `session.overlay.result` (retry
  while still running; targets the returned id with NO window scope, so a frontmost-window change can't
  desync the poll) → exit with the captured status into ONE blocking command (rejects `--block` + `--wait`
  at parse via `validate()`); the program's OUTPUT is its own concern — a TUI like revdiff renders in
  the overlay and writes results to its own `--output` file, which the caller reads (the control channel
  does NOT capture stdout).
  `session.overlay.resize` (target = session) resizes an ALREADY-OPEN overlay IN PLACE between full and
  floating — the way to change size without closing and re-running the program.
  Exactly one of `sizePercent` (1...100 → floating) or `full: true` (→ the full-pane overlay) must be set;
  both, neither, or a percent outside 1...100 is a dispatcher error (mirrored by the CLI `validate()`), and
  `no overlay` when none is open.
  It is a NEW `Command` case (unlike the `--follow` arg, which rode the existing `overlay.open`) because it
  needs its own arg validation, and `full` is a NEW `ControlArgs` field added to distinguish "switch to
  full" (nil `overlaySizePercent`) from "unset" on the wire.
  The arm mutates the non-persisted `Session.overlaySizePercent` via `AppStore.resizeOverlay` (clamping
  1...100, guarding `overlayActive`), and the detail pane re-flows the SAME surface host: the unified
  `WindowContentView.overlayPanel` now renders BOTH variants (full = translucent, no chrome, panes hidden by
  `hideForOverlay`; floating = opaque framed panel over visible panes), so a full<->% switch never re-parents
  the overlay NSView (which would blank its Metal drawable) nor changes the ZStack shape — the old
  `if fullOverlay` z2 sibling is gone, and the always-present `overlayPanel` at z3 is the single host.
  Four-point keep-in-sync audit for `session.overlay.resize`: (1) `case sessionOverlayResize = "session.overlay.resize"`
  + `ControlArgs.full` in `ControlProtocol.swift`, (2) the `.sessionOverlayResize` dispatcher arm (exactly-one
  + range validation) → the app-side `resizeSessionOverlay` (→ `AppStore.resizeOverlay`) behind `ControlActions`,
  (3) the `session overlay resize --size-percent|--full` subcommand (`Resize`, `validate()`-guarded) in
  `rookctlKit`, (4) round-trip in `ControlProtocolTests` + dispatcher routing/validation in `ControlDispatcherTests`
  + `AppStorePaneTests` (resize clamp/switch/no-overlay) + CLI mapping in `CommandsTests` + the e2e
  `testOverlayResizeSwitchesFloatingAndFull` in `ControlOverlaySplitUITests`.
  **`--pane left|right` scopes `session.overlay.open`/`.close`/`.result` to ONE split pane**, leaving the
  sibling live and interactive — a second agent, a diff, or a log next to the shell you keep working in.
  It is an ARG on the three existing commands, not a new `Command` case (the `--follow` precedent), parsed to
  the host-free `OverlayPane`, which takes the `TerminalZoomSurface` spellings MINUS `scratch`
  (`left`/`primary`, `right`/`split`) — there is no scratch pane to cover, so `scratch` is rejected even
  though `session.status --pane` accepts it.
  Omitted keeps the session-wide overlay, so every pre-pane caller is byte-identical on the wire.
  A pane overlay is ALWAYS FULL-PANE: `--pane` conflicts with `--size-percent` on open
  (`PaneOverlayError.sizePercentConflict`) and `session.overlay.resize` refuses ANY `--pane`, valid spelling
  or not (`resizeUnsupported`) — there is no per-pane size to change.
  Both overlay kinds are INDEPENDENT slots on the session, so a session-wide overlay and one or two pane
  overlays can be up at once.
  **Where each rejection lives is the dispatcher-first split taken literally**: the selector parse, the
  size conflict, and the resize refusal are host-free in `ControlDispatcher+Session`; `alreadyOpen` and
  `paneNotVisible` need the LIVE session and fire in `ControlServer`, so their wording is shared through
  `PaneOverlayError` rather than duplicated.
  `paneNotVisible` is not a nicety — an unrendered pane never gets a nonzero backing size, so its surface
  would never be created and the slot would sit open with no program, answering "overlay still running"
  forever (see [[libghostty]] for the retirement path that covers the pane going away AFTER the open).
  The `rookctl session overlay open --pane … --block` poll forwards `--pane` too: polling a pane overlay
  with no pane reads the session-wide slot, which is never running.
  A pane overlay is ZOOMABLE as its own surface (`surface:<id>:overlay-left|overlay-right`), and it is the
  last cover in `Session.topmostSurface` — below the session-wide overlay and the scratch, above the pane —
  which is what makes the ⌘W rung close it, ⌘F decline the pane beneath it, and `session.focus` route to it.
  Its READ side is `ControlSessionNode.paneOverlays` (`["left"]` / `["right"]` / `["left","right"]`, omitted
  when neither), independent of the `overlay` bool; those overlays are always full-pane, so there is no
  per-pane size to report.
  Four-point keep-in-sync audit: (1) the `ControlArgs.pane` doc + `ControlSessionNode.paneOverlays` +
  `PaneOverlayError` in `ControlProtocol.swift` and `ControlSessionOverlayOpenOptions.pane` +
  the `pane:` parameters on `ControlActions.closeSessionOverlay`/`sessionOverlayResult` in
  `ControlDispatcher.swift`, (2) the three dispatcher arms in `ControlDispatcher+Session.swift` →
  `AppStore.openPaneOverlay`/`closePaneOverlay`/`recordPaneOverlayExit` behind the `ControlServer` arms,
  (3) the `--pane` option on `session overlay open|close|result` in `rookctlKit`,
  (4) `ControlDispatcherOverlayPaneTests` + `AppStorePaneOverlayTests` + the `paneOverlays` round-trip in
  `ControlProtocolTests` + the CLI mapping in `CommandsTests`.
  The READ side is `ControlSessionNode.overlaySizePercent` on each `tree` node (see the `tree` read-side
  fields below) — populated in `AppStore.controlTree`, round-tripped by `treeSessionNodeRoundTripsWithOverlaySizePercent`/`…OmitsOverlaySizePercentWhenNil`
  and `AppStorePaneTests.controlTreeReportsOverlaySizePercent`, and mirrored in the agent-skill `reference.md`
  tree schema — so a script can record an overlay's size before zooming to `--full` and restore it exactly.

  **`session.hud.open`/`.update`/`.close` — the SECOND occupant of the session-wide overlay slot: a PASSIVE
  message panel, not a program.**
  It is control-NATIVE — no menu item, chord, or palette entry — a deliberate exemption from the
  shared-action-seam rule, because there is nothing here for a human to invoke by hand.
  Sharing the slot rather than adding a third one is what keeps the ⌘W ladder, `coverHidesActiveSession`,
  `searchTarget`, and session-close teardown unchanged.
  - **Passivity is ONE predicate, `Session.programOverlayActive` (`overlayActive && !hudActive`), read at
    every site that used to read the raw slot.**
    `overlayActive` now answers only "occupied"; asking it where the answer decides focus, coverage, or
    input hands first responder to the painter.
    The sites: the deck's `DeckPaneGates.coverActive`, the floating click-catcher and `backdropWashActive`
    (through `OverlayPanelStyle.backdrop`), the scratch's `isActive` gate, `TerminalView(viewOnly:)` on the
    panel, the `.onChange` key for the overlay-close refocus, `Session.topmostSurface`/`focusTarget(wantSplit:)`/`onScreenSurface`,
    `AppActions.searchTarget`'s scratch rung, the scratch factory's `suppressAutoFocus`, and all five
    `TerminalZoomSurface` terms.
    `viewOnly` owns the NSView layer, where `mouseDown` makes a surface first responder; the ancestor's
    `.allowsHitTesting(false)` blocks the click before that, so the two are belt and braces (the dashboard
    learned that `allowsHitTesting` alone is not what stops AppKit routing a click) — neither is the place
    to economise.
    Keying the refocus on the raw slot instead YANKS focus out of an open ⌘F field or an in-progress rename
    on every HUD close.
    Never spell the predicate inline; two spellings will disagree.
  - **Zoom must widen `uncovered` and narrow the `.overlay` arm TOGETHER.**
    Narrowing `.overlay` alone leaves NO case active with a HUD up and falls through to the
    documented-unreachable `?? .primary` fallback.
    A HUD is NOT addressable: `surface:<id>:overlay` is refused (`isAvailable` false), matching the same
    response's `overlay: false`.
  - **Constant shape, one host, one style value type.**
    `OverlayPanelStyle.resolve(session)` produces every per-occupant parameter (geometry, chrome, backdrop,
    interactivity, vertical placement), so `overlayPanel`'s modifier chain stays IDENTICAL across full,
    floating, and HUD — the NSSplitView-overrun invariant above, taken to a third occupant.
    `overlayPanel`'s `.id` carries `Session.overlaySlotGeneration` (bumped on every slot OPEN): a
    replacement keeps `overlayActive` true across the swap, so without a changing identity `makeNSView`
    never re-runs and `updateNSView` hits a torn-down view with `overlaySurface` nil.
  - **Two axes, measured separately (`HudLayout.panelSize` → one `HudPanelSize` store-to-deck).**
    Width from the box's columns, height from its rows.
    One percent across both made every panel as tall as it was wide — a square box around two lines of text
    — so `OverlayPanelStyle` carries `widthFraction`/`heightFraction` and only a PROGRAM overlay sets them
    equal.
    `--size-percent` reaches the WIDTH alone, on open and on `overlay.resize` (the text wraps at
    `HudLayout.maxColumns`, not at the panel, so a resize changes no rows), and the height takes no caller
    override at all — a set height can only strand the message in an empty box.
    Every HUD width passes `HudLayout.clampSizePercent` (10...80), the caller's included, so the `--full`
    refusal and the never-cover invariant cannot disagree; the height shares the 80 cap but takes NO minimum
    floor (the box already carries `verticalPadding`, and flooring it is the square again).
    That 80 cap is also what makes `top`/`bottom` always fit their `HudPosition.edgeMarginPercent`, the
    height being what decides how far the panel travels; `OverlayPanelStyle.verticalOffset`'s centering
    fallback is defensive only.
    An unmeasured pane splits the fallback: width takes `maxSizePercent` (nothing is known to fit), height
    takes `minSizePercent` (80% of a pane is a cover, not a message).
  - **One slot, ASYMMETRIC replacement.**
    A second `hud.open` replaces the first, `overlay.open` closes a HUD and proceeds, and a HUD over a
    RUNNING program is refused `overlay already open` — a message is replaceable, a program is not.
    `overlay.close`, ⌘W, and session close tear a HUD down as a courtesy.
    `overlay.result` refuses with `OverlayHudError.noResult` (the raw slot would answer the misleading
    "overlay still running" for a painter that will never report a status), and `overlay.resize` takes a
    percent but refuses `--full` (`OverlayHudError.fullResize`).
    Both of those `overlay.resize` arms — the `--full` refusal and the rollback that restores the previous
    width when the body write fails (`OverlayHudError.writeFailed`) — are covered by
    `rookTests/ControlServerHudResizeTests`, which stands up the app-target `ControlServer` fixture the
    former KNOWN GAP note said we lacked.
    Neither can be hoisted: the dispatcher hands `sizePercent` straight to the `ControlActions` witness, and
    the arm's two decisions read a LIVE session through `writeHudBody`/`paneMetrics`.
    Everything host-free underneath them was already covered (`AppStoreHudTests` resizes a HUD through the
    store's clamp), so the app-target file is the whole of the addition.
    **The fixture is the reusable part — a `ControlServer` transitively pulls in the whole app graph, and
    three constraints make it safe to build one inside a test:**
    (1) root the `WindowLibrary` in a throwaway directory, or it reads and rewrites the user's real
    `windows.json`;
    (2) never call `start()` on the DEFAULT socket path — the lock guard keeps it from displacing a running
    app, but with none running it would bind the real path and answer the user's next `rookctl`;
    `start()` on an explicit short `/tmp` path is fine, which is what `ControlServerTests` does;
    (3) hand `SettingsModel` the DEFAULT `SettingsStore`, not a throwaway one — its init writes
    `ghostty-settings.conf` into the STATE dir, a path it resolves from the environment rather than from its
    store's directory, so a throwaway store loads DEFAULTS and clobbers the user's real generated config,
    while the real store re-emits byte-identical text and writes nothing.
    That model is also why a `ControlServer` test is a last resort rather than the default home for a
    control arm: the dispatcher-first rule still applies, and anything that can answer without a live
    session belongs in `ControlDispatcher` with a host-free test.
  - **`HudSpinner` owns the spinner — one case per style, each carrying its own FRAMES and tick interval.**
    Both ride the body header, so the helper holds no glyph table, a new style is one edit, and `hud.update`
    switches style with no re-spawn.
    Frames must be single Unicode scalars that render ONE column and contain no space: the header is
    word-split, and `HudLayout.spinnerWidth` reserves exactly two cells.
    `dot`'s blank half is U+00A0 for that reason.
    The CLI keeps `--spinner` as the on switch for `HudSpinner.defaultStyle` and adds `--spinner-style`,
    which implies it; both resolve client-side, so `ControlArgs.spinner` always carries a style name or
    nothing and the dispatcher validates one thing.
    `HudSpinner.noneName` is ACCEPTED by both the socket AND the CLI — refusing it locally would fail a
    value `tree` had just handed the caller — and beats a bare `--spinner` beside it.
    Rejection messages list it through `acceptedNamesList`, never the styles alone.
  - **READ-BACK: `ControlSessionNode.hud` (`ControlHudNode`), with `overlay` FALSE and `overlaySizePercent`
    omitted beside it.**
    It carries BOTH shares (`sizePercent` = width, `heightPercent`), and `position` + `spinner` always
    report the EFFECTIVE value, defaults included — `spinner` names the STYLE and spells a static panel
    `noneName`, which the dispatcher takes back as "no spinner", so a caller round-trips what `tree` gave
    it.
    An update carries the OPEN's background color forward (the factory reads it once at creation), so
    `hud.backgroundColor` never names a color the panel will not paint.
    HUD state is poll-only: `openOverlay`/`closeOverlay` emit no `scheduleTreeChanged()` and neither does a
    HUD, so there is no event to document.
  - **The panel is a pty running the bundled `rook/Resources/hud/hud.sh`**, spawned `autoFocus: false` with
    `ROOK_HUD_FILE` as its only HUD-SPECIFIC variable (the surface still inherits the session environment
    and the overlay wrapper's `ROOK_OVL_*` pair) and capturing NO exit code.
    Grid, spinner (flag, interval and frames) and the APP'S PID ride that file's HEADER line and are
    re-read every tick, so `hud.update` repaints in place with no re-spawn; write it ATOMICALLY (the helper
    re-reads with no locking, so a partial write paints half a message).
    The file is per SESSION, so an update rewrites the path the running helper already opened.
    `Session.discardHudBody` is the ONLY deleter and every store teardown runs it — close, ⌘W,
    session/workspace/window teardown — so a HUD closed before its surface realized cannot strand the
    message text in a world-readable `/tmp` path.
  - **The header's grid is `HudLayout.paintGrid` — the PANEL's own cells (`panelGrid`), NOT `HudLayout.box`,
    which only decides the SIZE.**
    Both measure the same message, so they usually agree, but the panel is whole CELLS of a rounded percent
    and the box is not, and a `--size-percent` width detaches them outright; `box` is the fallback when
    nothing is measured.
    Every path that changes the panel's size — open, update, `overlay.resize` — must rewrite the header
    through `ControlServer.writeHudBody`, which reads the size the STORE resolved.
    A window resize is the one skew left, until the next update.
  - **The helper forces `LC_CTYPE=UTF-8` on itself**: `${#line}` counts BYTES otherwise, and a
    Dock-launched app inherits launchd's locale-less environment.
    Under it `${#line}` counts CODE POINTS, so the app measures in `HudLayout.cellCount` (Unicode scalars,
    precomposed first) rather than `String.count`, whose grapheme clusters disagree on every combining mark
    and ZWJ emoji.
    Neither side counts DISPLAY columns, so a double-width glyph overflows the frame — accepted, not fixed.
    It skips a repaint whose frame is byte-identical to the last, so a spinner-less panel writes once and
    stops waking the renderer (the demand-driven-rendering rule), and traps WINCH to invalidate that cache —
    a cache, not a measurement; the box still comes only from the body file.
  - **The helper needs a stop condition of its OWN: the app's pid, checked with a builtin `kill -0`.**
    A hard-killed app (crash, `kill -9`, XCUITest `terminate()`) runs no `destroySurface`, so the body file
    survives, and no SIGHUP arrives because the pty's session leader is the surviving `login` — without the
    pid every such exit leaves a 2–10 Hz repaint loop running forever.
    A header naming no owner (or a non-numeric one) keeps painting, leaving the file the only stop.
  - Four-point keep-in-sync audit for `session.hud.*`: (1) `case sessionHudOpen/Update/Close` +
    `ControlArgs.message`/`detail`/`spinner` + `ControlHudNode` + `OverlayHudError` in `rookCore`,
    (2) `ControlDispatcher+Hud.dispatchHudCommand` (all text/color/percent/position/spinner validation and
    the response shape) → the `ControlActions` witnesses `openHud`/`updateHud`/`closeHud`, implemented
    app-side in `rook/Control/ControlServer+HUD.swift` (helper path, font cell metrics, pane geometry, the
    body file) — a NEW family file, never `ControlServer+SessionActions.swift`,
    (3) the `session hud open|update|close` subcommand in `rookCore/Sources/rookctlKit/SessionOverlayCommands.swift`
    (`Open` is the default subcommand),
    (4) `HudTests` + `HudHelperTests` (the shipped `hud.sh` run for real) + `ControlDispatcherHudTests` +
    `AppStoreHudTests` + `ControlProtocolHudTests` + `HudCommandsTests` + the app-target `HudDeckGatesTests`
    and `ControlServerHudResizeTests` + the e2e `ControlHudUITests`.

  `surface.zoom` (mode `show`|`hide`|`toggle`) fills the target window with ONE terminal surface,
  hiding the sidebar and collapsing the title bar to a slim strip (traffic lights + an exit button;
  the zoomed terminal is inset below `titlebarHeight`, NOT borderless) — the control half of
  ⌘⇧Return / View ▸ Toggle Terminal Zoom (`BuiltinAction.toggleTerminalZoom`) and the title-bar exit button.
  Targets: omitted/`active` resolves the active surface (quick terminal first, else the active session's
  overlay > scratch > focused-split > primary via `TerminalZoomController.resolveTarget`, which derives the
  precedence from `TerminalZoomSurface.isActive`); an explicit `surface:<session-id>:<left|right|scratch|overlay>`
  id (from `tree`'s `surfaces` nodes) zooms that surface — hidden-but-alive splits/scratches included — and
  `quick` addresses a quick-terminal zoom (the API accepts the id it emits).
  State lives in the per-window, host-free `TerminalZoomController` (`rookCore/TerminalZoom.swift`,
  registered in `TerminalZoomRegistry`); the app-side arm (`setSurfaceZoom`/`setActiveSurfaceZoom`) only
  resolves the target and shapes the response — ALL mode-vs-state semantics stay in `TerminalZoomController.set`,
  shared with the GUI toggle, so the three callers can't drift.
  Zoom is a VIEW mode with hard invariants: it must not mutate split ratios, focus, sidebar state, or
  split/scratch visibility (the zoom host mounts with `reportsFocusChange: false` → `suppressFocusChange`
  on ALL `onFocusChange` paths, incl. `clearUnseenOnRefocus`), and the zoomed session's deck entry stays
  mounted with a CONSTANT shape — only the zoom-owned slot swaps to its `deckHostsSurface` placeholder —
  so control-opened split/scratch/overlay surfaces still realize and run behind the zoom layer.
  Entering zoom closes the window's transient chrome (the palette — frontmost window only, it is
  app-global — an active ⌘F search, and, for a session zoom, a visible quick terminal); a
  notification-banner reveal exits zoom first; ⌘W exits zoom (the topmost cover, stepwise like the
  quick/overlay/scratch dismissal); font commands stay live (they act on the focused = zoomed surface).
  While zoomed, `quick show` and `session.search` (except `close`) are rejected; `quick hide` stays
  idempotent (a zoomed quick terminal un-zooms first, so a script can always dismiss it), and an
  explicit-target `surface.zoom hide` skips the availability check so hide is idempotent even after
  the surface vanished.
  The READ side is `ControlTree.zoomedSurface` at the tree TOP level — the zoomed surface's control id
  (`surface:<session-id>:<kind>` or `quick`), nil/omitted when nothing is zoomed — LIVE, resolved
  app-side in `buildTree` from the projected window's `TerminalZoomController.target?.controlID` and
  threaded as a `zoomedSurface: () -> String?` closure on `AppStore.controlTree` (the `quickVisible`
  seam), `tree`-only for the same staleness reason; so a script can check "is it already zoomed" and
  record-then-restore. The per-session `surfaces` nodes are the ADDRESSING list, not the state read-back:
  `ControlSurfaceNode.active`/`visible` derive from session flags (overlay/scratch/splitFocused), are
  identical zoomed or not, and `visible` reads false for a pane behind a FLOATING overlay even though
  that pane is visually on screen — documented as a caveat on the node type and in the skill.
  Four-point keep-in-sync audit: (1) `case surfaceZoom = "surface.zoom"` + `ControlSurfaceNode`/`ControlSessionNode.surfaces`
  + `ControlTree.zoomedSurface` in `ControlProtocol.swift`, (2) the `.surfaceZoom` arm (`setSurfaceZoom`) in `ControlServer+SurfaceZoom.swift`
  + the `surfaces`/`zoomedSurface` population in `AppStore.controlTree`/`buildTree`, (3) the `surface zoom` subcommand in `rookctlKit`,
  (4) round-trip in `ControlProtocolTests` (incl. `treeRoundTripsWithZoomedSurface`/`…OmitsZoomedSurfaceWhenNil`)
  + `TerminalZoomTests` + the e2e `ControlSurfaceZoomUITests` (incl. the tree read-back and the
  `--window`-scoped error paths).
  `dashboard` opens a view-only GRID of live session surfaces over the window (up to `DashboardLayout.maxCells`
  = 9 cells, laid out `ceil(sqrt(n))`), or `--close`s the open one.
  The cell unit is a session+PANE: a non-split session is one cell, a split session expands to TWO (its
  `.primary` and `.split` panes), so the 9-cell cap counts PANES — the expansion + cap live in the host-free
  `AppStore.dashboardMembers(for:limit:)`, shared by the control arm and the GUI toggle, and any dropped pane
  is REPORTED in `result.text` alongside any unresolved id (never a silent drop).
  Args: positional ids (`ControlArgs.targets`), `--mru` (fill from the window's recency instead of naming ids
  — resolved app-side via `AppStore.recentSessions(limit:)`, so it takes no ids), `--font-size N` (absolute
  points) XOR `--auto-size` (scale to the grid), `--close`, and the global `--window`.
  The dispatcher (`ControlDispatcher.dispatchDashboard`) owns every flag rule host-free — `--close` takes
  nothing else, `--mru` excludes explicit ids, `--font-size` excludes `--auto-size`, a non-finite/non-positive
  size errors — and builds the `DashboardFontMode`; the app-side `ControlServer.setDashboard`
  (`ControlServer+Dashboard.swift`) owns target resolution, the pane expansion, the surface reparent, and the
  per-window `DashboardController` via `DashboardControllerRegistry`.
  Zoom and the dashboard are MUTUALLY EXCLUSIVE (opening one closes the other), and while it is open the
  window swaps its full titlebar for a stripped `dashboardTitlebar` (exit button only) so no chrome button can
  steal first responder from the grid's key-catcher and strand Esc.
  Our Markdown/file-tree panels stay MOUNTED but non-interactive behind it (the existing `deckInteractive`
  gate covers hit-testing) — they are NOT dismissed.
  GUI half: `BuiltinAction.dashboard` (⌘⇧D) → `AppActions.toggleDashboard()` (opens the MRU set, auto-sized),
  the Navigate ▸ Dashboard menu item, and the ⌃⇧P palette's "Dashboard".
  READ-BACK: four `tree` TOP-LEVEL fields, all LIVE (resolved app-side per request from the window's
  `DashboardController`, `tree`-only like `zoomedSurface` since the keyboard-driven grid bypasses the command
  path): `dashboardMembers` (the pane refs `<session-uuid>:left`/`:right` in grid order),
  `dashboardHighlighted` (the cell Enter would jump into), `dashboardFontSize` (the applied points), and
  `dashboardFontMode` (`auto`|`fixed`|`untouched`) — all omitted when no dashboard is open.
  Four-point keep-in-sync audit: (1) `case dashboard` + `ControlArgs.close`/`fontSize`/`autoSize`/`mru` + the
  four `ControlTree` fields in `ControlProtocol.swift`, (2) the `.dashboard` dispatcher arm →
  `ControlActions.setDashboard` (app-side `ControlServer+Dashboard`) + the four read-back closures in
  `buildTree`, (3) the `dashboard` subcommand (`validate()`-guarded) in `rookctlKit`, (4) round-trip in
  `ControlProtocolTests` + `ControlDispatcherDashboardTests` + `DashboardLayoutTests`/`DashboardControllerTests`
  + `AppStoreDashboardTests` + CLI mapping in `CommandsTests` + the e2e `DashboardUITests`.

  **`pick.open`/`pick.result`/`pick.cancel` — the native picker, and the one command family whose POINT is
  asking the HUMAN a question.**
  An agent driving rook can read state and act, but it had no way to say "which of these?" and get an answer;
  `pick.open` puts a caller-supplied list into the same palette UI the user already knows, and the answer
  comes back over the socket.
  - **`pick.open`** takes `args.items` (`[ControlPickItem]` = `{id, label, subtitle?}`), plus `prompt`
    (placeholder), `query` (opens already filtered), `allowCustom` (accept the typed query as the answer),
    `follow` (raise the target window), and the global `--window`.
    It returns the new picker's id in `result.id` (a fresh UUID), NOT the answer — the answer is read back.
  - **`pick.result <id>`** returns the nested `ControlPickResult` = `{result, id?, label?, index?, query?}`,
    where `result` is `pending`|`picked`|`custom`|`cancelled`.
    `pick.cancel <id>` resolves a pending picker as `cancelled`.
    Both are addressed by PICK ID and take no window selector: the id is globally unique, so a poll finds its
    picker wherever it lives — which is what lets a poll survive the window closing under it.
  - **Validation is dispatcher-owned** (host-free, `ControlDispatcher+Pick.swift`), and the strings are pinned:
    `pick.open requires items`, `pick.open requires at least one item` (an EMPTY list is legal only with
    `allowCustom` — a picker with nothing to pick is a free-text prompt, not an error),
    `too many items (max 1000)` (`ControlPickItem.maxItems`), `pick item label must not be empty`,
    `pick item ids must be unique`, `item text must not contain control characters` (the same invisible-control
    vector the store's name sanitizing closes), `pick.result requires a pick id`,
    `pick.cancel requires a pick id`.
    App-side adds `pick already pending` (one picker per window), `unknown pick: <id>`, `no open window`, and
    `no pick surface`.
  - **Matching is LABEL-ONLY for a caller-supplied list**, unlike the action palette's fuzzy scoring over the
    whole row: the caller controls the labels, and scoring the subtitle too would let a row win on text its
    author never meant as a key (`PaletteSearchKeys`, host-free + unit-tested).
    An EMPTY query preserves CALLER ORDER rather than re-sorting, so a list that is already ranked stays
    ranked; the query is trimmed first, because a trailing newline (a shell here-doc's parting gift) scored
    every row zero and silently destroyed that order.
  - **Retention is why a slow human does not break a script.** A resolved answer is kept after the picker
    closes: 8 per window (`PickController.retainedResultLimit`) and 32 app-wide for windows that have since
    closed (`PickRegistry`), evicted oldest-ANSWER-first by a monotonic resolution sequence rather than
    per-window, so a poll landing after teardown still reads its own result instead of an error.
  - **Every path that could strand a waiting caller resolves the pick instead of hiding it**: ⌘W (the first
    rung of the close ladder, ABOVE terminal zoom), the window actually closing, and app termination
    (`cancelAllPendingPicks` on `willTerminate`).
    A pending picker is also a MODAL for our purposes — `uiActionsEnabled` gains a `pickActive` term, so the
    palettes, quick terminal, zoom, dashboard and search decline to steal its first responder.
  - **`rookctl pick` is the ergonomic half**: `pick` alone is `pick open` (default subcommand), reading items
    from stdin as one label per line (the label doubles as the id) or as a JSON `[{id,label,subtitle?}]` array
    when the first non-whitespace byte is `[`.
    It BLOCKS by default — polling ten times at 100 ms and then every 500 ms, because a human choice takes
    seconds to minutes and hammering a serial accept loop for that long is rude — and exits `0` for
    picked/custom, `1` for pending, `2` for cancelled, so a shell script branches on `$?` alone.
    `--no-block` prints the id and returns, leaving `pick result`/`pick cancel` to the caller.
    A transport failure mid-poll sends a best-effort `pick.cancel` on a fresh connection, so an abandoned
    caller does not leave a picker up on the user's screen.
  - **READ-BACK is `ControlTree.pickPending`** at the tree top level: the id of the picker awaiting an answer
    in that window, omitted when none.
    It is `tree`-only and resolved LIVE app-side (the user answers with the keyboard, no command involved, so
    a cached `window.list` copy would go stale) — the same treatment as `zoomedSurface` and the dashboard
    fields.
  Four-point keep-in-sync audit: (1) `case pickOpen`/`pickResult`/`pickCancel` + `ControlArgs.items`/`prompt`/
  `query`/`allowCustom` (reusing `follow`) + `ControlPickItem`/`ControlPickOutcome`/`ControlPickResult` +
  `ControlTree.pickPending` in `rookCore`, (2) the dispatcher arm (`ControlDispatcher+Pick.swift`) →
  `ControlActions` witnesses in `ControlServer+Pick.swift` (a NEW family file — `+SessionActions.swift` is at
  its size limit) plus the `pickPending` closure in `buildTree`, (3) the `rookctl pick open|result|cancel`
  subcommand tree in `rookctlKit/MiscCommands.swift`, (4) `PickTests` + `ControlDispatcherPickTests` +
  `PaletteSearchKeysTests` + `PickCommandsTests` + round-trip in `ControlProtocolTests` + the e2e
  `ControlPickUITests`.

  Mode-bearing commands (`session.split`/`quick`) compute the delta against current state so `on`/`off`/`show`/`hide`
  are idempotent, and an unknown mode is an error.
  `quick`'s visibility reads back on `ControlTree.quickVisible` at the tree TOP level — LIVE, resolved
  app-side in `buildTree` from the projected window's `QuickTerminalController.isVisible` (the window id
  found by store identity, `library.openIDs().first { library.store(for:) === store }`, since the quick
  terminal is per-window); `tree`-only like `sidebarMode` (the GUI ⌃` toggle bypasses the command path, so
  a cached `window.list` copy would go stale), so a script can make the `quick` toggle idempotent.
  Threaded as a `quickVisible: () -> Bool?` closure on `AppStore.controlTree` (defaulting nil for host-free
  tests), covered by `treeRoundTripsWithQuickVisible`/`treeOmitsQuickVisibleWhenNil` +
  `AppStoreTests.controlTreeReportsQuickVisibleFromClosure`; the app-side `QuickTerminalRegistry` read is build-verified.
  `quick.type`/`quick.text` are the input/read-back pair for the quick terminal, the twins of `session.type`/`session.text`
  (the quick terminal is the one typing surface the socket couldn't reach before — issue #170).
  Both are frontmost-window-only (no `--target`/`--window`/`--pane`; the quick terminal is a single per-window surface),
  dispatcher-owned via `ControlActions.typeQuick(text:)` / `readQuickText(all:lines:)` (both `async`), and inject/read
  through the same `GhosttySurfaceView.inject(text:)` / `readScreenText(all:lines:)` primitives the session commands use.
  They are `async` because `quick show` flips `isVisible` before SwiftUI mounts + libghostty realizes the surface, so
  a bounded main-actor poll (12×30 ms, the `session.type` realize-poll pattern) waits out the mount — `quick show; quick
  type` back-to-back is reliable rather than racing.
  Fast-fail when NOT racing: `quick terminal not open` when the overlay has never been shown (no surface AND not visible,
  so the poll returns at once), `quick terminal not realized` / `failed to read surface buffer` if a shown surface never
  comes up within the poll, `no open window` when there is no window.
  A shown-then-hidden quick terminal keeps its surface alive, so it types/reads while hidden (like `session.type --pane
  scratch`).
  `quick.text` is the read-back for `quick.type` (there is no NEW tree-node field — you read via the sibling `text`
  command, exactly as `session.text` reads back `session.type`).
  Covered by the `quickType*`/`quickText*` `ControlDispatcherTests` + the e2e `testQuickTypeAndReadText`
  (type a marker, read it back off the quick surface).
  `session.status` flags a per-session agent status on the sidebar row — `args.status` is `idle`|`active`|`completed`|`blocked`
  (`AgentStatus(rawValue:)` → an `invalid status` error on anything else),
  `args.blink` pulses the glyph, and `args.autoReset` (status-agnostic, caller-set,
  symmetrical with `blink`) makes it clear back to idle once the session is visited.
  `args.sound` plays a ONE-SHOT sound when the status is applied (caller-driven,
  NOT stored on `AgentIndicator` — `default`/`beep` = `NSSound.beep()`, any other value = the named system
  sound via `NSSound(named:)`, which also resolves custom sounds in `~/Library/Sounds`);
  it is validated UP-FRONT against the app-side `StatusSoundPlayer.shared` (a singleton that caches resolved
  `NSSound`s so a short clip isn't cut off when the local goes out of scope — also reused by the Settings
  picker preview), so an unknown name is an `unknown sound: X` error that leaves the status UNCHANGED,
  and the fire is inside `resolveSession` so a bad target still errors `notFound` without playing.
  When NO per-call `args.sound` is given and a session TRANSITIONS into `blocked`,
  the user's **Settings ▸ Appearance ▸ Agent Status ▸ Blocked sound** (`AppSettings.blockedStatusSoundName`,
  GUI-only, default None) plays as a best-effort default.
  The transition is gated by a `wasBlocked` read of the session's current status BEFORE `setAgentIndicator`,
  so a REPEATED `blocked` set does not replay the default (and an empty per-call `args.sound` counts
  as unset); the precedence is the host-free `AgentStatus.effectiveSound(perCall:blockedDefault:)` (explicit
  per-call wins; the default is blocked-only), with the transition gate itself in the server.
  That setting is keep-in-sync EXEMPT like the status colors, since the per-status sound already has
  full control coverage via `--sound`.
  `args.color` (`#rrggbb`, REUSING the `session.background`/`session.overlay.open` field — no new arg —
  validated by the shared `WatermarkConfig.isValidColorHex` in the dispatcher, an `invalid color (expected #rrggbb)`
  error that leaves the status UNCHANGED) is a per-call glyph-tint OVERRIDE.
  It rides the ephemeral `AgentIndicator` (`AgentIndicator.color`), so — because `setSessionStatus` builds
  a fresh indicator every call — the next `session.status` without a color naturally DISCARDS it (no explicit
  clear); nil renders the Settings-configured status color.
  Both glyph render sites resolve it through the SHARED `GhosttyApp.statusColor(for:override:)` (a valid
  hex wins, nil/malformed falls back to `statusColor(for:)`): the AppKit sidebar `StatusIconView` and the
  SwiftUI attention-list `StatusGlyph` (`PaletteItem.statusColor`), so they can't drift.
  It is keep-in-sync EXEMPT like the status colors/sound — the per-call color has full control coverage
  via `--color` and no GUI setter (the Settings colors are the app-wide default, not a per-session tint).
  Setting a non-idle status is control-driven (the hooks/agents call it;
  no GUI sets active/completed/blocked), but clearing to idle ALSO has a GUI — the **Clear Status** action
  (see the Agent-status glyph note) — so the idle case is keep-in-sync covered by `session.status idle`.
  Cross-window via the shared `resolveSession` (the install's Stop hook targets its own `$ROOK_SESSION_ID`,
  which may live in a non-frontmost window).
  The arm (`setSessionStatus`) builds an `AgentIndicator{status, blink, autoReset, color}` (host-free,
  ephemeral — never in `SessionSnapshot`) and drives the single `AppStore.setAgentIndicator(_:forSession:)`
  mutation point (unknown id = clean no-op), returning the id.
  Four-point keep-in-sync audit for `session.status --color`: (1) `ControlArgs.color` (reused) +
  `AgentIndicator.color` + `ControlSessionStatusUpdate.color` in `rookCore`, the dispatcher hex-validation,
  (2) the `.sessionStatus` arm threading `update.color` into the indicator + the two render sites via
  `GhosttyApp.statusColor(for:override:)`, (3) the `session status --color` option (`validate()`-guarded)
  in `rookctlKit`, (4) round-trip in `ControlProtocolTests` + dispatcher validation in `ControlDispatcherTests`
  + `AgentStatusTests` (indicator color + Equatable) + CLI mapping in `CommandsTests` + the e2e
  `testSessionStatusColorValidatesHex` in `ControlSidebarStatusUITests` (asserts the command path — the
  glyph TINT itself is not accessibility-observable).
  **`args.shape` (`session.status --shape circle|square|triangle|diamond|capsule|star`) is the SECOND
  visual axis, an OPT-IN addition to the semantic glyph — never a new default.**
  It exists because the tint alone does not always read (color blindness, a monochrome theme, a small
  glyph), so the silhouette can carry the state too.
  The raw value parses to the host-free `StatusShape` (its `rawValue` IS the SF Symbol base name; the
  drawn symbol is the `.fill` variant, so a shaped glyph is a solid silhouette rather than an outline),
  and an unknown name is rejected in the DISPATCHER before any mutation —
  `invalid shape: <raw> (circle|square|triangle|diamond|capsule|star)`, built from
  `StatusShape.validNamesList` so the message can't go stale — leaving the status UNCHANGED, exactly like
  a bad `--color`/`--pane` (the whole point of `dispatchSessionStatus` validating every argument up front:
  a typo can never both change the status and return an error).
  The CLI pre-validates the same set in `validate()` (`shape must be one of: circle, square, …`, from
  `StatusShape.validNamesPhrase`).
  It rides the ephemeral `AgentIndicator.shape` exactly like `--color`, so the next `session.status`
  WITHOUT a shape discards it — there is no explicit clear.
  **`--shape` is an OVERRIDE, and the precedence is per-call > configured > semantic.**
  The per-call value beats the Settings-configured per-status shape
  (`AppSettings.effectiveStatusShape(for:)`, see the Settings rule), which in turn beats the status' own
  semantic symbol — the same three-tier shape the `--color` override already has over the configured status
  color.
  The reason the per-call leg wins is that it is a deliberate statement about THIS report from a hook that
  knows something the standing preference does not.
  The resolver is the single host-free
  `AgentStatus.symbolName(override:configured:)` = `override?.symbolName ?? configured?.symbolName ?? symbolName`;
  with both nil every glyph on screen and every field on the wire is byte-for-byte what it was (pinned by an
  `AgentStatusTests` case over all states).
  **Our built-in defaults stay SEMANTIC and are deliberately NOT upstream's.**
  Upstream's series (agterm `21d17537`+`03e0e83b`+`939e3d1b`) also flipped the built-in glyphs so all three
  states draw a bare `circle.fill` and differ only by tint, and added a Settings shape picker to compensate
  for that regression; we took the CONTROL leg only.
  `active`=`ellipsis.circle.fill`, `blocked`=`exclamationmark.circle.fill`,
  `completed`=`checkmark.circle.fill`, `idle`=no glyph are unchanged.
  We DID later take upstream's Settings picker (the per-status configured shape), but on our own terms:
  because our defaults are semantic, nil is NOT Circle here, so the picker needs an explicit **Default**
  entry that upstream's option list does not have — see the Settings rule for that menu.
  Both render sites go through that ONE host-free resolver — the AppKit sidebar `StatusIconView` and the
  SwiftUI twin `StatusGlyph` — and the PER-CALL half is threaded through all THREE carriers that feed the
  twin (`PaletteItem.statusShape`, `SessionSwitcherRow.statusShape`, the recent-sessions popover row);
  without that last leg the parameter would exist but nothing would pass it, and a shaped session would
  draw the shape in the sidebar and the semantic default in the palette / Ctrl-Tab switcher / popover.
  The CONFIGURED half needs no carrier at all: both render sites read it straight off
  `GhosttyApp.statusShape(for:)` (the shape twin of `statusColor(for:override:)`), so a new carrier never
  has to be threaded for it and the two sites cannot drift.
  Read back as `ControlSessionNode.statusShape` (the `StatusShape` raw value, omitted when idle or when no
  per-call shape is set), next to `statusColor`/`statusBlink` — the PER-CALL override ONLY.
  `AppStore.controlTree()` builds it from `session.agentIndicator.shape`, so a session drawing the user's
  CONFIGURED shape reports no `statusShape` at all — exactly like `statusColor`, which likewise omits the
  configured tint, so record-then-restore treats the two alike and restores the override without freezing
  the standing preference into it.
  Four-point keep-in-sync audit for `session.status --shape`: (1) the `StatusShape` enum +
  `AgentStatus.symbolName(override:configured:)` + `AgentIndicator.shape` + `ControlArgs.shape` +
  `ControlSessionStatusUpdate.shape` + `ControlSessionNode.statusShape` in `rookCore`, plus the dispatcher
  parse/validation in `dispatchSessionStatus`, (2) the `.sessionStatus` arm threading `update.shape` into
  the indicator + the two render sites + the three carriers, (3) the `session status --shape` option
  (`validate()`-guarded) in `rookctlKit`, (4) round-trip + omit-when-nil in `ControlProtocolTests` +
  dispatcher validation in `ControlDispatcherTests` + `AgentStatusTests` (the resolver over every state ×
  shape, including the no-shape identity over `AgentStatus.allCases`) + the tree read-back in
  `AppStoreOrganizationTests` + CLI mapping in `CommandsTests`.
  Control-native like `--color`/`--sound`: no GUI sets the PER-CALL override (the Settings picker sets the
  standing default, a different value on a different lifetime — GUI-only and keep-in-sync EXEMPT, same class
  as the status colors), and the silhouette is no more accessibility-observable than the tint (the
  `agent-status` element's value stays the state name).
  `args.pane` (`left`|`right`|`scratch`, REUSING the shared `--pane` addressing vocabulary — parsed to the
  host-free `StatusPane` and validated by the dispatcher, an `--pane must be left, right, or scratch` error
  that leaves the status UNCHANGED) records WHICH pane set the status onto the ephemeral `AgentIndicator.statusPane`
  (nil/omitted is treated as `left` = the main pane).
  It drives two consumers.
  (1) Pane-scoped keystroke-clear: the main/split/scratch surface factories each wire `onUserInputClearsStatus`
  to a closure that clears only when the host-free `AgentIndicator.clearedBy(pane:isInterrupt:)` says the keystroke's
  OWN pane owns the current status, so a `right`- or `scratch`-tagged block SURVIVES foreground typing in the
  main pane (see the Notifications rule).
  (2) Pane-aware attention navigation: auto-follow and the GUI attention-nav (⌃⌥↑/⌃⌥↓, menu, palette) reveal
  and focus the tagged pane — flip `splitFocused` to the split, or show a hidden scratch via `AppStore.toggleScratch`
  — instead of always the main pane (the shared `AppActions.revealActiveBlockedPane`, wired into
  `selectNext/PreviousAttentionSession` + `autoFollowed`).
  The `session.go next-attention|prev-attention` control arm (`goSession`) only drives `AppStore.navigateSession`
  and does NOT call the reveal, so the socket steps the selection but does not itself move focus into the pane
  (see the Menu/actions rule).
  It reads back on each `tree` node as `ControlSessionNode.statusPane` (omitted when nil, gated on the SAME
  non-idle condition as `status` so an idle node reports neither).
  The `--blink` flag and the `--color`/`--shape` overrides read back the same way —
  `ControlSessionNode.statusBlink` (`true` when blinking, omitted otherwise), `statusColor` (the `#rrggbb`,
  omitted when using the default color) and `statusShape` (the `StatusShape` raw value, omitted when
  drawing the semantic default glyph), all populated in the tree builder gated on the SAME non-idle
  condition — so a script can record the FULL status (state + pane + blink + color + shape) and restore it.
  Four-point keep-in-sync audit for `session.status --pane`: (1) the `StatusPane` enum + `AgentIndicator.statusPane`
  + `AgentIndicator.clearedBy(pane:isInterrupt:)` + `ControlSessionStatusUpdate.pane` + `ControlSessionNode.statusPane`
  + `SurfaceEnvironment.session(pane:)` (injects `ROOK_PANE`) in `rookCore`, plus the dispatcher `StatusPane`
  parse/validation, (2) the `.sessionStatus` arm threading `update.pane` into the indicator + the per-factory
  `ROOK_PANE` env + the pane-scoped keystroke-clear closures + the `revealActiveBlockedPane` nav step,
  (3) the `session status --pane` option (`validatePaneArgument`-guarded) + the hook wrapper forwarding
  `$ROOK_PANE` as `--pane`, (4) round-trip in `ControlProtocolTests` + dispatcher validation in `ControlDispatcherTests`
  + `AgentStatusTests` (the `clearedBy` truth table) + `SurfaceEnvironmentTests` + `AgentStatusWrapperTests`
  + CLI mapping in `CommandsTests` + the e2e in `PaneAwareStatusUITests`.
  It is control-native for the tag itself (no GUI sets a pane), the same keep-in-sync footing as `--color`/`--sound`.
  **`args.paneID` (`session.status --pane-id TOKEN`) is the STABLE companion to the mutable `--pane` role.**
  The role is BAKED into the shell at spawn and goes stale: when the primary pane exits and the split
  survivor is promoted into the main slot (`closePrimaryPane`), that shell keeps its baked
  `ROOK_PANE=right` — re-split the session and BOTH shells believe they are the right pane, so a `blocked`
  lands on the wrong one, and the `!hasSplit` coercion cannot tell them apart because it only knows whether
  a split exists at all.
  So each session-owned surface (main/split/scratch) now ALSO gets a fresh per-surface token baked as
  `ROOK_PANE_ID` (`SurfaceEnvironment.session(…, paneToken:)`, a `UUID` minted in `rookApp.surfaceEnv`;
  the overlay and quick terminal pass nil and get none), exposed as the `TerminalSurface.paneToken`
  protocol requirement — no default, so a future surface fails to COMPILE rather than silently returning
  an empty token.
  The app-side arm resolves it against the session's LIVE surfaces via `Session.paneRole(forToken:)`
  (`surface` → `.left`, `splitSurface` → `.right`, `scratchSurface` → `.scratch`), so the role is computed
  when the status is REPORTED rather than baked when the shell started.
  Precedence: a token that RESOLVES overrides `--pane`; an empty or unknown one falls back to it — which is
  what keeps shells spawned before the token existed, AND an older installed copy of the hook, working
  exactly as before.
  That fallback is also why the `!hasSplit` coercion stays: it is the safety net on precisely that path, and
  a resolved `.right` always implies a live `splitSurface`, hence `hasSplit`, so the two layers cannot fight.
  The token is opaque — validated only by whether it resolves — and needs no read-back field of its own
  (`statusPane` already reports the resolved role).
  The installed `rook-agent-status.sh` forwards BOTH (`--pane "$ROOK_PANE"` and `--pane-id "$ROOK_PANE_ID"`,
  each appended only when set), so scripts normally leave `--pane-id` to the hook.
  **Because installing the hooks is a COPY, an existing install does NOT forward the token until the user
  re-runs Help ▸ Install Agent Status Hooks…** — the merge is idempotent and upgrades the managed block.
  Keep-in-sync: `ControlArgs.paneID` + `ControlSessionStatusUpdate.paneID` + `TerminalSurface.paneToken` +
  `Session.paneRole(forToken:)` + `SurfaceEnvironment`'s `ROOK_PANE_ID` in `rookCore`, the
  `GhosttySurfaceView.paneToken` witness (reading its own baked env back) + the `resolvedPane` line in
  `ControlServer+SessionActions.setSessionStatus`, the `session status --pane-id` option in `rookctlKit`,
  and `SessionTests`/`SurfaceEnvironmentTests`/`AgentStatusWrapperTests`/`ControlProtocolTests`/`ControlDispatcherTests`/`CommandsTests`.
  **Any doc that lists the spawned shell's `ROOK_*` variables, or shows scrubbing them for a daemon/tmux
  (`env -u ROOK_ENABLED -u ROOK_PANE …`, tmux `set-environment -g -r`), MUST include `ROOK_PANE_ID`** — a
  recipe that misses it no longer cleans everything the app bakes, which is functional, not cosmetic.
  **`args.agentPid` — the SAME ownership check `session.agent` runs, but FAIL-OPEN and THREE-CONDITIONED.**
  It exists because a NESTED agent PROCESS — a `claude -p …` the pane's own agent spawned through Bash —
  inherits the pane's `ROOK_SESSION_ID`/`ROOK_PANE`, so its hooks used to drive the sidebar row: it
  finished, reported `completed`, and the row said "done" while the pane's real agent was still working.
  A status is DROPPED only when all three of these hold, and each one exists to kill a specific false drop:
  1. **The call NAMES the caller's own session** — a CLI-side condition.
     `Session.Status.makeRequest` reports `AgentProcess.nearestAgentPid()` ONLY when `--target`
     case-insensitively equals the shell's `$ROOK_SESSION_ID`; otherwise it sends NO pid and the server
     never weighs one.
     Without this, an orchestrator agent flagging ANOTHER session would hand over the pid of ITS OWN
     pane's foreground, compare it against a pane it was never running in, and have every cross-session
     report silently dropped.
     The default `--target active` fails the test too, on purpose — `active` is whatever pane the user is
     looking at, which is not a claim about ownership.
     The installed hook always passes `--target "$ROOK_SESSION_ID"`, so the case the check exists for
     stays covered, and a NESTED agent inherits that same variable and is still caught.
  2. **An AGENT sits at the head of the resolved pane** — an app-side condition.
     `isForeignAgent` classifies the pane's foreground argv with `AgentKind.classify`, the very call
     `AgentMonitor` makes for the sidebar logo (via `ForegroundProcess.command(for:shellBasename:)`, which
     already returns nil for an idle shell).
     Behind **tmux or ssh** the foreground process is the WRAPPER and the agent lives under it, so the pid
     could not match even for the pane's rightful agent — judging ownership there would have broken every
     tmux user's status reporting, which works today.
     That regression would have been worse than the bug being fixed.
  3. **The pids differ.**

  Only then: `ok: true` + `result.text = "ignored: not the pane's agent"`, with no indicator mutation and
  no sound.
  Everything else PASSES — no `agentPid`, no `GhosttySurfaceView`, no readable `foregroundPid()`, a
  non-agent foreground.
  That is the OPPOSITE default to `session.agent`'s, which drops on any unproven case: `session.agent`
  writes PERSISTENT state, where losing a write beats storing a stranger's;
  a status is EPHEMERAL, and losing a `blocked` — the agent waits on a human while the row stays silent —
  is worse than one stray `active`.
  The comparison uses `resolvedPane`, so a status sent with the promoted pane's `--pane-id` is checked
  against THAT pane's foreground, not the main one.
  **This is a DIFFERENT hole from the `background_tasks` substitution in `rook-agent-status.sh`** (see the
  Notifications rule): the pid check catches nested agent PROCESSES, which have their own pid;
  the substitution catches a main thread ending its turn over live IN-PROCESS background work (Task,
  teammates, workflows), whose hooks run in the pane's own `claude` and therefore MATCH the pane's
  foreground pid.
  Neither subsumes the other.
  Keep-in-sync: `ControlSessionStatusUpdate.agentPid` (LAST in `init`, so existing call sites keep
  compiling) + the `request.args?.agentPid` passthrough in `ControlDispatcher.dispatchSessionStatus`
  (no validation — it is not user input) + the `ownershipPid` gate in `rookctlKit`'s
  `Session.Status` + `isForeignAgent` in `ControlServer+Agent.swift`.
  No read-back field is owed: the pid is not session state, it is a proof of origin, and the status it
  gates already reads back on `tree` as `status`/`statusPane`.
  Visibility is keep-state vs one-time, decided by `autoReset` alone: `AppStore.selectSession` resets
  an `autoReset` indicator (the `completed` flash) to idle on BOTH the session visited AND the one left
  (right after `clearUnseen`), so it never lingers on a row you switch away from,
  and leaves a non-`autoReset` one untouched.
  The glyph is NOT gated by selection — it shows on every non-idle session,
  the selected one included (see below).
  `session.agent` (target = session) remembers which agent CONVERSATION a pane is on, so a restart can
  RESUME it instead of coming back on a blank agent.
  It is control-NATIVE (no GUI/menu equivalent — only the agent knows its conversation id) and is meant to
  be called by the agent's own `SessionStart` hook, the same footing as `session.status`.
  `args.agent` is the `AgentKind` raw value (`claude`|`codex`, anything else is an
  `invalid agent (expected claude or codex)` error), `args.agentID` the conversation id (nil CLEARS the
  pane's ref — the `--clear` idiom), `args.configDir` the agent's config root at launch
  (`CLAUDE_CONFIG_DIR`/`CODEX_HOME`; the CLI defaults it from its own environment), and `args.pane` the
  shared `StatusPane` addressing vocabulary restricted to `left`|`right` — `scratch` is a
  `session.agent supports --pane left or right` error, since the scratch terminal is not restored.
  The host-free half (kind + pane validation, the ref, the response shape) is
  `ControlDispatcher.dispatchSessionAgent`; the app-side `ControlActions.setAgentSession`
  (`ControlServer+SessionActions.swift`) owns target resolution + the ownership check and drives the single
  `AppStore.setAgentSession(_:forSession:pane:)` mutation point (which normalizes a `.right` pane to the
  main pane on a session with NO split, exactly like `setAgentIndicator` does — a promoted split survivor
  keeps its baked `ROOK_PANE=right`).
  **Ownership check (`args.agentPid`).** A hook cannot prove WHICH agent fired it from its environment: a
  nested `claude -p` that the pane's own agent spawns inherits the same `ROOK_SESSION_ID`/`ROOK_PANE`, so
  without a check its throwaway conversation would clobber the pane's.
  The process TREE can tell them apart — the CLI reports its nearest agent ANCESTOR's pid
  (`rookctlKit/AgentProcess.nearestAgentPid`, a `sysctl(KERN_PROC_PID)` parent walk), and only the pane's
  own agent is that pane's FOREGROUND process.
  A mismatch is DROPPED: reported `ok` (a hook must never fail the agent's turn) with
  `result.text = "ignored: not the pane's agent"`, but nothing is written; a nil `agentPid` (a human
  running `rookctl` by hand) SKIPS the check rather than rejecting.
  Unlike the ephemeral `AgentIndicator`, the ref is PERSISTED (`Session.agentSession`/`splitAgentSession`
  → `SessionSnapshot`) — surviving the restart is the entire point — so a changed value saves.
  RESTORE side: `rookApp.restoreInitialInput` renders the host-free `AgentResume.resumeLine(argv:ref:)`
  into the restored shell's `initial_input` INSTEAD of the plain `CommandRestore.shellQuotedLine`, gated on
  `AppSettings.resumeAgentSessions` (which itself rides `restoreRunningCommand` — see the Settings rule).
  The line is `env CLAUDE_CONFIG_DIR='<dir>' claude --resume <id> <surviving flags>` (codex:
  `env CODEX_HOME='<dir>' codex resume <id>`); the `env` prefix is deliberate (it execs the binary from
  PATH, bypassing a shell function/alias wrapping the agent's name, which would re-pick a profile and lose
  the conversation), and `AgentResume.strippedArgs` drops any `-c`/`--continue`/`-r`/`--resume` (+ its id),
  `--fork-session`, and a leading codex `resume`/`fork` subcommand so nothing fights the resume.
  With no reported id (the hook isn't installed) it falls back to `claude --continue` / `codex resume
  --last`.
  READ-BACK: `ControlSessionNode.agentSession`/`splitAgentSession` — the `AgentSessionRef`
  (`{kind, id, configDir?}`) of the main / split pane, omitted when nil.
  DISTINCT from the sibling `agent` field, which is merely WHICH agent the pane RUNS (derived from the
  foreground process, no write command): `agent` is observed, `agentSession` is REPORTED.
  Four-point keep-in-sync audit for `session.agent`: (1) `case sessionAgent = "session.agent"` +
  `ControlArgs.agent`/`agentID`/`configDir`/`agentPid` (reusing `pane`) + `AgentSessionRef` +
  `ControlSessionNode.agentSession`/`splitAgentSession` + `ControlAgentSessionUpdate` + the host-free
  `AgentResume`/`AgentHookPayload` in `rookCore`, (2) the `.sessionAgent` dispatcher arm →
  `ControlActions.setAgentSession` (app-side ownership check + `AppStore+Agent`) + the two fields populated
  in the tree builder, (3) the `session agent <claude|codex> [--id|--from-hook|--clear] [--config-dir]
  [--pane]` subcommand (`validate()`-guarded; `--from-hook` parses stdin with `AgentHookPayload`, so the
  installed hook script needs no `jq`) in `rookctlKit`, (4) round-trip + omit-when-nil in
  `ControlProtocolTests` + `AgentResumeTests` (the resume line, the stripped flags, the payload parse) +
  dispatcher validation in `ControlDispatcherTests` + CLI mapping in `CommandsTests` + the e2e.
  `keymap.reload` re-reads `keymap.conf` and returns the parse-diagnostic count in `result.count` (0
  reads as a clean reload; `rookctl keymap reload` prints `ok` then, else `N diagnostic(s)`).
  It is the SAME `SettingsModel.reloadKeymap()` path the GUI's File ▸ Reload Keymap menu/palette item
  drives, so the GUI half and the control half can't diverge — control-native only in the count it reports
  back; no `--window` selector (the keymap is app-global — a single app-wide `SettingsModel`,
  constructed once in `rookApp.init` and shared with `ControlServer`).
  Four-point keep-in-sync audit for `keymap.reload`: (1) `case keymapReload = "keymap.reload"` in `ControlProtocol.swift`
  (returns the new `ControlResult.count: Int?`, no target/args), (2) the `.keymapReload` dispatch arm
  in `ControlServer`, (3) the `keymap reload` subcommand in `rookctlKit`,
  (4) round-trip tests in `ControlProtocolTests` plus the e2e in `ControlAPIUITests`.
  See the Keymap section for the parser/menu/monitor design.
  `keymap.list` is the READ half of `keymap.reload`, which only ever answered with a diagnostic COUNT — a
  script could apply a keymap but never read what it resolved to, or why it broke.
  It takes no target/args and, like `keymap.reload`, has NO `--window` selector (app-global).
  `result.keymap` (`ControlKeymap` in the new `rookCore/Sources/rookCore/ControlKeymap.swift`) carries four
  things: `path` (which `keymap.conf` produced this), `actions` — every `BuiltinAction` in `allCases`
  declaration order with its resolved `chord` (kitty syntax, omitted when keyless) and `overridden: true`
  when that chord DIFFERS from the shipped `defaultChord`, `commands` (each custom command's `name` +
  `shortcut`, the latter omitted for a palette-only one), and `diagnostics` as `{line, message}` pairs.
  **`overridden` compares CHORDS, not the presence of a `map` line** — a redundant `map cmd+w close_session`
  parses fine and leaves the action on its default, and flagging that would report a difference the caller
  can see nowhere else.
  **The fifth field, `menu`, is the point of the command**: an app-side walk of `NSApp.mainMenu`
  (`ControlServer+KeymapCommands.swift`) reporting the LIVE key equivalents in the SAME kitty syntax, so
  each row compares directly against an `actions` row — `{menu, title, chord, selector, enabled}`, omitted
  entirely when the menu bar could not be read.
  The two halves are meant to be DIFFED: SwiftUI defers its menu rebuild to the next app activation, so a
  chord can be correct in the model and stale, hijacked by a stock AppKit item, or sitting on a DISABLED
  item — and only the `menu` half shows that (`selector` is `menuAction:` for rook's own SwiftUI items,
  anything else — `performClose:`, `closeAll:` — is an AppKit-supplied competitor).
  `enabled: false` is reported because a disabled item's chord is INERT: AppKit consumes the key equivalent
  and fires nothing, not even a same-chord enabled sibling, and most File/View/Navigate items carry a
  `modalActive` gate, so with the dashboard open the menu is largely inert while still holding every chord.
  This is the exact class of bug the ⌘W-vs-stock-File-▸-Close reconcile fixed by hand (see the Keymap
  section), which is why the diagnostic exists.
  `rookctl keymap list` renders it as sections — `keymap: <path>`, `actions:`, `commands:`, `diagnostics:`,
  `menu:` — where `*` marks an overridden action, `-` an action with no key (keyless actions are LISTED,
  not dropped, so the output is the full action set), `(disabled)` an inert menu row, and a diagnostic with
  `line == 0` (the whole-file / cross-section sentinel) prints with no line number, matching
  `SettingsView.diagnosticLine`.
  One shipped default renders un-typeable on purpose: `increase_font_size` is ⌘+, printed `cmd++`, which
  does not re-parse (`+` is the chord joiner) — reported verbatim anyway, because the `menu` half renders
  it identically and a placeholder would turn the one row that compares correctly into a false mismatch.
  Four-point keep-in-sync audit for `keymap.list`: (1) `case keymapList = "keymap.list"` +
  `ControlKeymap`/`ControlKeymapAction`/`ControlKeymapCommand`/`ControlKeymapDiagnostic`/`ControlKeymapMenuItem`
  + `ControlResult.keymap` + `Keybind.namedKey(forKeyEquivalent:)` in `rookCore`,
  (2) the `.keymapList` dispatcher arm → `ControlActions.listKeymap`, whose app-side witness is
  `ControlServer+KeymapCommands.swift` (a NEW file — `reloadKeymap()`'s home, `+SessionActions.swift`, is
  at its size limit) doing the `NSApp.mainMenu` walk and calling the host-free `ControlKeymap.project`,
  (3) the `keymap list` subcommand in `rookctlKit` (`BasicOptions` only, no `--window`) +
  `SocketClient.formatKeymap`, (4) `ControlKeymapTests` (the projection) + round-trip in
  `ControlProtocolTests` + dispatcher routing in `ControlDispatcherTests` + `KeybindTests` (the
  keyCode/keyEquivalent set-equality guard against `bindableNamedKeys`) + `CommandsTests` +
  `SocketClientTests` (the rendering).
  `config.reload` re-reads the rook-scoped `ghostty.conf` and returns the ghostty config-diagnostic
  count in `result.count` (0 reads as a clean reload; `rookctl config reload` prints `ok` then,
  else `N diagnostic(s)`).
  It is the SAME `AppActions.reloadGhosttyConfig()` path the GUI's File ▸ Reload Config menu/palette
  item + the Edit-ghostty overlay close drive (which posts the warning banner on a malformed file),
  so the GUI half and the control half can't diverge — control-native only in the count it reports back;
  no `--window` selector (the config is app-global — one `SettingsModel` + one `GhosttyApp`,
  shared with `ControlServer`).
  The arm calls `actions.reloadGhosttyConfig()` then returns `GhosttyApp.shared.lastConfigDiagnosticsCount`.
  Four-point keep-in-sync audit for `config.reload`: (1) `case configReload = "config.reload"` in `ControlProtocol.swift`
  (reuses `ControlResult.count`, no target/args), (2) the `.configReload` dispatch arm (`reloadGhosttyConfig`)
  in `ControlServer`, (3) the `config reload` subcommand in `rookctlKit`,
  (4) round-trip tests in `ControlProtocolTests` plus the e2e in `ControlAPIUITests`.
  See the Settings section for the config layer + Edit/Reload.
  `sidebar` (mode `show`|`hide`|`toggle`, default toggle, frontmost window — mirrors `quick`,
  delta-computed so it's idempotent, unknown mode + no-open-window are errors) shows/hides the custom-split
  sidebar — the per-window `AppStore.sidebarVisible` (persisted per-window in `Snapshot`,
  restored on relaunch alongside `AppStore.sidebarWidth`; `toggleSidebar`/`setSidebar` call `save()`;
  the custom split replaced `NavigationSplitView`, so there is no system toggle).
  `AppActions.toggleSidebar()` flips `library.activeStore?.sidebarVisible` and `WindowContentView` animates
  it (`splitRoot`'s `.animation(value:)`, so every caller animates uniformly — the toolbar button no
  longer wraps its own `withAnimation`); shared by the title-bar `sidebar-toggle-button`,
  View ▸ Show/Hide Sidebar, the ⌃⇧P palette "Toggle Sidebar", and the ⌃⌘S keymap action (`BuiltinAction.toggleSidebar`,
  expressible so pure-`defaultChord`-driven).
  Four-point keep-in-sync audit: (1) `case sidebar` in `ControlProtocol.swift` (reuses `ControlArgs.mode`),
  (2) the `.sidebar` dispatch arm (`setSidebar`) in `ControlServer`, (3) the `sidebar` subcommand in
  `rookctlKit`, (4) round-trip in `ControlProtocolTests` + the e2e `testSidebarShowHideToggle` (sidebar
  hide removes the `session-row`s from the AX tree) in `ControlSidebarStatusUITests`.
  `theme.set` sets + persists a theme (see the Theme picker section) PER SLOT, mirroring the two Settings pickers over the shared `SettingsModel.setLightTheme`/`setDarkTheme`/`setSystemThemes`.
  `args.name` (alias `args.light`; both together is an error) sets the light/single `theme` slot,
  KEEPING the `darkTheme` slot if one is set (they are separate fields, no recompose);
  nil/empty = ghostty's built-in / "default ghostty" (NOT the seeded `rook` app default),
  and a bare `theme set` clears BOTH slots + turns syncing off.
  `args.dark` sets the `darkTheme` slot alone and turns appearance syncing ON (`followSystemAppearance`,
  the light side seeds from the current theme, else `Builtin Light`);
  the reserved value `none` clears the dark slot (syncing off, the light side survives as the plain theme).
  The `.themes` palette commit maps to the CURRENT appearance's slot (NO live preview over the socket — preview is interactive-only).
  An unknown name (not in `SettingsCatalog.themeNames()`) is an `unknown theme: X` error (a typo silently
  doing nothing is worse than a fail); the response always echoes the full post-change state
  (`result.theme`/`sync`/`light`/`dark`).
  `theme.list` returns `result.themes` = the bundled names + `result.theme` = the plain current one (nil =
  ghostty built-in; absent on a fresh install means the seeded `rook` is current) + `result.sync`/`light`/`dark`;
  while syncing `result.theme` is ABSENT — the state rides the three sync fields.
  `rookctl theme list` prints one name per line with a leading "default ghostty" row,
  the active marked `* ` (both sides + a header while syncing), and `theme.set` prints `ok` (non-create mutation).
  App-global like `keymap.reload` (one `SettingsModel`), so NO `--window` selector.
  Four-point keep-in-sync audit: (1) `case themeSet = "theme.set"` + `case themeList = "theme.list"`
  in `ControlProtocol.swift` (reuse `ControlArgs.name`; add `ControlResult.theme`/`themes`),
  (2) the `.themeSet` (`setTheme`, with name validation) + `.themeList` dispatch arms in `ControlServer`,
  (3) the `theme set [name] [--light] [--dark]` / `theme list` subcommands in `rookctlKit` (+ `SocketClient.formatThemes`),
  (4) round-trip in `ControlProtocolTests` + the e2e `testThemeListAndSet` in `ControlAPIUITests` and `testThemeSyncWithSystemAppearance` in `ControlAPIThemeUITests`.
  See the Theme picker section for the GUI/preview half.
  `session.flag` (target = session) flags/unflags a session for the flagged working-set view — `args.mode`
  is `on`|`off`|`toggle`|`clear` (`clear` IGNORES the target and unflags every session in the resolved
  store via `AppStore.clearFlags()`, mirroring `session.scratch`/`session.split`'s mode-bearing shape),
  drives `AppStore.setFlag(_:forSession:)` (idempotent — no-op + no save when unchanged),
  surfaces the `flagged` bool on `ControlSessionNode` in the `tree` builder,
  and returns the session id; an unknown mode is an error.
  It is the control half of the row context-menu Flag/Unflag + the View-menu/palette Flag Session/Clear
  Flagged.
  Pair with `sidebar.mode flagged` to view just the flagged sessions.
  Four-point keep-in-sync audit for `session.flag`: (1) `case sessionFlag = "session.flag"` in `ControlProtocol.swift`
  (reuses `ControlArgs.mode`; adds `flagged` to `ControlSessionNode`), (2) the `.sessionFlag` dispatch
  arm (`setSessionFlag`) in `ControlServer`, (3) the `session flag on|off|toggle|clear` subcommand (`FlagCommand`)
  in `rookctlKit`, (4) round-trip in `ControlProtocolTests` + the e2e `testSessionFlagAndSidebarModeFlagged`
  in `ControlSidebarStatusUITests`.
  `session.seen` (target = session) clears a session's unseen-notification badge WITHOUT changing the
  selection, focus, or agent status — the focus-free counterpart to `notify`, which raises the badge over
  the socket while the only clear paths (`AppStore.selectSession`, a pane's `onFocusChange(true)`) are
  both focus-coupled.
  It drives the already-public `AppStore.clearUnseen(_:)` (the same primitive `selectSession` calls),
  so it is idempotent (a no-op when already zero; the count is ephemeral, absent from `SessionSnapshot`,
  so it triggers no save) and returns the session id; NO args beyond target/window (leaner than `session.flag`
  — no mode).
  It is control-NATIVE (no GUI/menu equivalent — visiting the session is the GUI's only "mark seen", and
  it is inseparable from selecting) — the same footing as `notify`/`session.type`/`session.copy`.
  The read side is the new `unseen` field on `ControlSessionNode` (the `session.unseenCount`, populated
  in the `tree` builder, omitted when zero), so a script can query the count and clear it symmetrically.
  Four-point keep-in-sync audit for `session.seen`: (1) `case sessionSeen = "session.seen"` +
  `unseen: Int?` on `ControlSessionNode` in `ControlProtocol.swift` (no new `ControlArgs` field),
  (2) the `.sessionSeen` dispatch arm (`markSessionSeen`) in `ControlDispatcher`/`ControlServer` + the
  `unseen` population in `AppStore.controlTree`, (3) the `session seen` subcommand (`Seen`) in `rookctlKit`,
  (4) round-trip (`sessionSeenRoundTrips` + `treeSessionNodeRoundTripsWithUnseen`/`…OmitsUnseenWhenNil`)
  in `ControlProtocolTests` + dispatcher routing in `ControlDispatcherTests` + `AppStoreTests`
  (`controlTreeReportsUnseenCountWhenPositive`/`…OmitsUnseenCountWhenZero`) + CLI mapping in `CommandsTests`
  + the e2e `testSessionSeenClearsBadgeWithoutFocus` in `ControlSidebarStatusUITests`.
  `sidebar.mode` (frontmost window) flips the sidebar VIEW between the workspace tree and the flat flagged
  working-set list — `args.mode` is `tree`|`flagged`|`toggle` (delta-computed against `AppStore.sidebarMode`
  so it's idempotent, unknown mode = error), drives `setSidebarViewMode` → `AppStore.setSidebarMode`.
  It is the control half of the bottom-bar `flagged-view-toggle` + the View-menu Show Flagged/Show All
  + `BuiltinAction.toggleFlaggedView`; the existing `sidebar [show|hide|toggle]` is now the default `sidebar visibility`
  subcommand alongside `sidebar mode`.
  Its READ side is `ControlTree.sidebarMode` at the tree TOP level (`AppStore.sidebarMode.rawValue`,
  `tree`|`flagged`), the read side of this write-only command so a script can record and restore the view
  mode — the sibling of `sidebarVisible`, except `tree`-ONLY (not mirrored onto the cached `window.list`,
  since the GUI `flagged-view-toggle` bypasses the command path and would leave a cached copy stale).
  Four-point keep-in-sync audit: (1) `case sidebarMode = "sidebar.mode"` in `ControlProtocol.swift` (reuses
  `ControlArgs.mode`), (2) the `.sidebarMode` dispatch arm (`setSidebarViewMode`) in `ControlServer`,
  (3) the `sidebar mode tree|flagged|toggle` subcommand (`Mode`, alongside the `Visibility` default)
  in `rookctlKit`, (4) round-trip in `ControlProtocolTests` + the e2e `testSessionFlagAndSidebarModeFlagged`
  in `ControlSidebarStatusUITests`.
  `sidebar.expand`/`sidebar.collapse` expand every workspace / collapse all but the active one in a window's
  sidebar TREE — `expand` drives `AppActions.expandAllWorkspaces(in:)`, `collapse` drives `collapseOtherWorkspaces(in:)`
  (collapse keeps the ACTIVE session's workspace expanded and scrolls its row into view).
  UNLIKE `sidebar`/`sidebar.mode` (frontmost-only, no selector), these honor the global `--window` selector
  (`ControlArgs.window`): the arm resolves the target store via `resolvePlacementStore(window)` (frontmost
  by default; a named window must be OPEN, else the closed-window error;
  no open window at all → `no open window`), then posts a notification (`.rookExpandWorkspaces`/`.rookCollapseWorkspaces`)
  carrying THAT `AppStore` as the object.
  `WorkspaceSidebar.Coordinator` registers its observer with `object: store`,
  so NotificationCenter delivers ONLY to that window's sidebar Coordinator — this object-scoping (the
  rename notifications self-scope via the selected-session guard; expand/collapse have no such natural
  guard) is exactly what lets the control path target a specific (even background) window while the GUI
  menu/palette use the frontmost.
  A graceful no-op in `flagged` mode (no workspace rows: `expandWorkspacesNotified` gates on tree mode,
  `collapseOthers` gates internally); idempotent.
  GUI half (frontmost only): View ▸ Expand/Collapse Workspaces (plain keyless items,
  disabled with no active store or in flagged mode) + the ⌃⇧P palette "Expand Workspaces"/"Collapse Workspaces"
  (tree-mode only).
  Four-point keep-in-sync audit: (1) `case sidebarExpand = "sidebar.expand"` + `case sidebarCollapse = "sidebar.collapse"`
  in `ControlProtocol.swift` (reuse `ControlArgs.window`, no new field),
  (2) the `.sidebarExpand`/`.sidebarCollapse` dispatch arms (`expandWorkspaces(window:)`/`collapseWorkspaces(window:)`)
  in `ControlServer`, (3) the `sidebar expand`/`sidebar collapse` subcommands (`Expand`/`Collapse` on
  `ClientOptions` for `--window`, alongside the `Visibility` default + `Mode`) in `rookctlKit`,
  (4) round-trip (incl. the windowed variant) in `ControlProtocolTests` + the e2e `testSidebarExpandCollapse`
  in `ControlSidebarStatusUITests`.
  **Caveat — these two are NOTIFICATION-ONLY, so `collapsed` is not a reliable read-back for them.**
  They post `.rookExpandWorkspaces`/`.rookCollapseWorkspaces` and the MOUNTED `WorkspaceSidebar` does the
  mutating; the sidebar is mounted only while the window's sidebar is VISIBLE, so with it hidden the pair
  changes nothing a script can read (the command still answers ok).
  That is exactly why the per-workspace pair below writes the store FIRST.
  `workspace.collapse`/`workspace.expand` (target = workspace) collapse/expand ONE workspace in a window's
  sidebar tree — the per-workspace analogue of the all-workspace `sidebar.expand`/`sidebar.collapse`.
  Both resolve through the shared `resolveWorkspace` and honor the global `--window` selector like the other
  workspace commands, drive the delta-guarded `AppStore.setWorkspaceExpanded` (so a repeat is a clean no-op),
  and return the workspace id.
  **Order is load-bearing: the arm persists `Workspace.isExpanded` on the store FIRST and only THEN posts
  `.rookSetWorkspaceExpanded` for the live outline** (store-scoped `object: store` like the expand/collapse-all
  pokes, so only the target window reacts) — the store is the source of truth for the `collapsed` read-back,
  and a notification-only write would silently drop with the sidebar hidden, which is the whole defect the
  all-workspace pair still has.
  There is deliberately NO `AppActions` hop: unlike the all-workspace pair this has no GUI caller (a row
  click drives the `NSOutlineView` directly), so the control arm is its only entry point.
  `workspace.new --collapsed` (`ControlArgs.collapsed`, threaded into `AppStore.addWorkspace(name:collapsed:)`)
  creates the workspace already closed, so a script can build one and fill it with `session.new --no-select`
  without it popping open; the CLI sends the field ONLY when the flag is set, so the default stays
  byte-identical on the wire.
  The READ side is `ControlWorkspaceNode.collapsed` on each `tree` workspace node: `true` when collapsed,
  OMITTED when expanded — expanded is the default, matching the persisted `WorkspaceSnapshot.collapsed` —
  so a script can record a workspace's open/closed state and restore it, or toggle by reading it first.
  It reports the persisted model state (`!isExpanded`), independent of a transient focus force-reveal.
  CLI: `rookctl workspace collapse|expand [--target <id>]` (`TargetOptions`, defaulting to `active` — the
  id is an OPTION here, not a positional, unlike `window minimize`) and `rookctl workspace new [name] --collapsed`.
  Four-point keep-in-sync audit: (1) `case workspaceCollapse`/`case workspaceExpand` + `ControlArgs.collapsed`
  + `ControlWorkspaceNode.collapsed` in `ControlProtocol.swift`, (2) the two dispatcher arms →
  `ControlActions.setWorkspaceExpansion` + the widened `createWorkspace(window:name:collapsed:)` (the old
  two-argument overload is DELETED — the protocol requires `collapsed:`, so it witnessed nothing), both
  app-side in the NEW `ControlServer+WorkspaceCommands.swift`, plus `collapsed` in the tree builder,
  (3) the `workspace collapse`/`workspace expand` subcommands + `workspace new --collapsed` in `rookctlKit`,
  (4) round-trip + omit-when-nil in `ControlProtocolTests` + dispatcher routing in `ControlDispatcherTests`
  + `AppStoreOrganizationTests` (the mutator + tree read-back) + CLI mapping in `CommandsTests`.
  `workspace.focus` (target = workspace) marks or unmarks ONE workspace in the sidebar's focus SET — the
  working set the tree is filtered to when the filter applies.
  It honors the global `--window` selector and returns the workspace id, and the state is per-window +
  persisted, orthogonal to `sidebar.mode` (the flat flagged list ignores focus entirely).
  `args.mode` is `on`|`off`|`toggle`|`add`, and each mode is stated on BOTH axes — the SET and the FLAG —
  because the two move independently and a mode that says only "focuses it" is unusable:
  - `on` REPLACES the set with the target and APPLIES the filter: the single-workspace zoom.
  - `off` REMOVES the target from the set, leaving every other member alone; the filter switches off as the
    set empties.
    **`off` IS the remove mode** — there is deliberately no separate `remove` token, because once the focus
    is a set, "unfocus this workspace" and "drop it from the set" are the same act, and two tokens for it
    would just be two ways to spell the same mutation.
  - `toggle` REPLACE-toggles: clears everything when the target is the SOLE marked workspace and the filter
    applies, else replaces the set with the target and applies.
    **There is deliberately NO membership-toggle mode.**
    A mode that flipped membership would compete with this one for the same obvious token, and nothing needs
    it: the sidebar row's Add/Remove item computes its own direction from the `marked` it just read and
    sends `add` or `off`, which is what any script should do too.
  - `add` INSERTS the target alongside the existing members and leaves the FLAG exactly as it was.
    **An `add` NEVER enables the filter.**
    An add that applied it would collapse the tree onto the first member and hide the very rows the next add
    needs, so a set is instead built row by row with the whole tree on screen and applied ONCE.
  **The mode is parsed and rejected in the DISPATCHER, which pays off the last of the dispatcher-first
  debt.**
  `workspace.focus` was the final mode-bearing command still validating its mode app-side — in violation of
  this file's own dispatcher-first rule — and now parses to the typed `ControlWorkspaceFocusMode` before the
  host runs, so an unknown mode can never half-apply.
  That is its OWN vocabulary rather than the shared `ControlToggleMode` because `add` has no answer for that
  type's whole contract, `desiredValue(current:) -> Bool` — `add` is not a boolean at all.
  The rejection is `invalid focus mode: <raw> (on|off|toggle|add)`, whose accepted list is
  `ControlWorkspaceFocusMode.validNamesList` (derived from `allCases`, the `StatusShape.validNamesList`
  precedent), so adding a mode cannot leave the message stale.
  The `ControlActions.focusWorkspace` requirement takes the TYPED mode, and the whole mode-to-mutator
  mapping is the host-free `AppStore.applyFocusMode(_:to:)` — so the app-side arm is target resolution and
  nothing else, and the GUI's replace-toggle and the wire's `toggle` are literally the same function
  (`AppStore.toggleFocusedWorkspace`) and cannot come to mean two things.
  Every mutator underneath is delta-guarded, so all four modes are idempotent.
  **`workspace.focus add` and `workspace.filter` ship as a PAIR by design.**
  Because an `add` never enables, a set built with repeated `add` has NO way to be applied except
  `workspace.filter on`: the additive builder and the applier are two halves of one gesture.
  Shipping `add` alone would leave a set applicable only through `on`, which throws the set away first.
  GUI half: the workspace row's context menu — Focus/Unfocus (the replacing `toggle`) plus the additive
  Add to Focus / Remove from Focus, which is where the absent membership-toggle mode goes, since the row
  knows its own membership and sends `add` or `off` — View ▸ Focus/Unfocus Workspace
  (`BuiltinAction.focusWorkspace`) + View ▸ Add Workspace to Focus + View ▸ Clear Focus, and the ⌃⇧P
  palette's "Focus Workspace"/"Add Workspace to Focus"/"Clear Focus".
  CLI: `rookctl workspace focus [on|off|toggle|add] [--target W]` (mode defaults to `toggle`), whose
  abstract, per-mode argument help, and local `validate()` rejection ALL derive from
  `ControlWorkspaceFocusMode.allCases` (`validNamesList`/`helpPhrase`/`validNamesPhrase`) — so a new mode
  reaches every one of them and the CLI cannot drift from the dispatcher's parse.
  **A quiet BACKGROUND create must not widen a script's set.**
  `AppStore.addWorkspace`/`ensureWorkspace` take `revealNewWorkspace` (default true): a plain
  `workspace.new` JOINS the marked set while the filter applies, matching the GUI's New Workspace button —
  the user asked for that workspace, so hiding it behind the filter would be absurd.
  `workspace.new --collapsed` and `session.new --no-select --create-workspace` pass
  `revealNewWorkspace: false` instead, because both are by definition quiet creates (a collapsed workspace
  is being built to be filled; a `--no-select` session deliberately leaves the selection alone), and
  widening the working set behind the caller's back is the opposite of what either asked for.
  **`workspace.filter on|off|toggle` is the APPLY leg of that focus, and the only way to switch the filter
  back on.**
  The focus state is two independent fields on `AppStore`: WHICH workspaces are marked
  (`focusedWorkspaceIDs`, a `Set<UUID>`) and WHETHER that set filters the tree (`focusEnabled`) — see the
  Sidebar rule.
  An INVOLUNTARY jump across the tree (idle auto-follow to a blocked session, attention nav, a
  notification reveal, the dashboard, the recent-sessions popover) drops only the FLAG and keeps the SET,
  which is exactly the state this command re-applies; before it existed, a hand-curated focus was
  unrecoverable.
  It is WINDOW-scoped, so unlike every other `workspace.*` command it takes NO `--target`: the global
  `--window` selector picks the store like `sidebar.expand`/`sidebar.collapse` (frontmost by default,
  `no open window` when there is none), and the CLI shape is `rookctl workspace filter [on|off|toggle]
  [--window W]` (mode defaults to `toggle`).
  The mode parses through the shared `ControlToggleMode` in the dispatcher (`invalid workspace filter
  mode: <raw>`); the on/off/toggle semantics are host-free in `AppStore.applyWorkspaceFilter` →
  `setFocusEnabled`, whose delta guard makes all three modes idempotent, so the app-side arm
  (`ControlServer.setWorkspaceFilter`) is pure store resolution.
  Enabling with NOTHING marked is a clean no-op — there is nothing to filter to, and switching the flag on
  over an empty set would report "focus restored" while the whole tree is on screen.
  A marked-but-DELETED workspace can no longer reach that state at all: removing a workspace drops it from
  the set (`dropFocusMember`) and a restore prunes ids absent from the rebuilt tree, so `focusEnabled` with
  an empty set is unrepresentable rather than merely refused.
  Disabling is never gated: `off` must always be able to undo.
  GUI half: the bottom-bar `focus-filter-toggle` (accessibility identifier), View ▸ Toggle Workspace Filter,
  the ⌃⇧P palette's "Toggle Workspace Filter", and the keyless `BuiltinAction.toggleWorkspaceFilter`.
  That toggle REPLACED the old bottom-bar focus PILL, and the replacement is the point rather than a
  restyle: the pill rendered the EFFECTIVE focus, so an involuntary jump that dropped the flag took the way
  back with it, while the toggle is both the indicator and the control and is the only affordance that still
  works while the filter is OFF.
  It is disabled with nothing marked (matching the store's refusal to enable an empty set), and since an SF
  Symbol is not accessibility-observable its `accessibilityValue` (`on`/`off`) is the only accessible read of
  whether the filter applies.
  **Read-back is THREE fields, a DELIBERATE divergence from upstream (agterm `6722755a`).**
  Per workspace node, `ControlWorkspaceNode.focused` is the EFFECTIVE focus and `marked` is MEMBERSHIP;
  at the `tree` top level, `workspaceFilter` is the flag (`tree`-only like `sidebarMode`, since an
  involuntary jump flips it with no command involved and a cached `window.list` copy would go stale).
  The invariant is **`focused == marked && workspaceFilter`**.
  Upstream instead REDEFINED `focused` itself, from "the tree is collapsed to this workspace" to mere
  membership, and has no `marked` field.
  Here that would be a SILENT breaking change: a script doing record-then-restore through `focused` would
  start reading `true` while the tree is NOT collapsed and "restore" a focus that was never applied — a
  regression that never fails, it just does the wrong thing in code we cannot see.
  So `focused` keeps exactly its old meaning (nil the moment the filter stops applying, even though the
  workspace stays marked) and the set state is read through the two new fields.
  Without `marked`, "marked but not filtering" and "nothing marked at all" would look identical from
  outside, and a script could not tell whether `workspace.filter on` has anywhere to go — nor watch a set
  being built, since `workspace.focus add` marks without enabling and `marked` is the only field that moves.
  An EXPLICIT `workspace.focus … off` (or the row menu's Remove from Focus) unmarks, so `marked` goes nil
  too.
  **The row-visibility contract, in FULL — a workspace ROW is visible iff**
  `tree.sidebarVisible && tree.sidebarMode == "tree" && (!tree.workspaceFilter || marked)`.
  Every term rides the same `tree` response, so a script evaluates it without a second call.
  The states, enumerated: `sidebarVisible == false` renders no sidebar at all; `sidebarMode == "flagged"`
  renders a FLAT flagged-session list with NO workspace rows, whatever the filter and the membership say;
  `"tree"` with the filter OFF renders EVERY workspace regardless of membership; `"tree"` with the filter ON
  renders only the members.
  **Neither shorter form is safe.**
  `focused` alone (equivalently `marked && workspaceFilter`) claims nothing is visible whenever the filter is
  off — precisely when the whole tree is on screen — and a script correcting for that reaches for
  `workspace.focus on`, which REPLACES the set with one workspace instead of re-applying the set it had.
  A bare `!workspaceFilter || marked` claims rows are visible in `flagged` mode and behind a hidden sidebar,
  where no workspace row renders at all.
  The filter-ON term is EXACT rather than approximate, because `workspaceFilter == true` with an empty set is
  unrepresentable (see the invariant above), so an applied filter always has at least one visible member.
  Four-point keep-in-sync audit for the pair: (1) `case workspaceFocus`/`case workspaceFilter` in
  `ControlProtocol.swift` (both reuse `ControlArgs.mode`) + `ControlWorkspaceFocusMode` in
  `ControlModes.swift` + `ControlWorkspaceNode.focused`/`marked` + `ControlTree.workspaceFilter` +
  `AppStore.applyFocusMode`/`applyWorkspaceFilter` and the `AppStore+Focus.swift` mutators in `rookCore`,
  (2) the `.workspaceFocus`/`.workspaceFilter` dispatch arms (mode parse + rejection) →
  `ControlActions.focusWorkspace(_:window:mode:)`/`setWorkspaceFilter(window:mode:)`, app-side in
  `ControlServer+SessionActions.swift`/`ControlServer+WorkspaceCommands.swift`,
  (3) the `workspace focus [on|off|toggle|add]` (`Focus`, `TargetOptions`) and
  `workspace filter [on|off|toggle]` (`Filter`, `ClientOptions` only — no `--target`) subcommands in
  `rookctlKit`, (4) round-trip + omit-when-nil in `ControlProtocolTests` + dispatcher routing/mode rejection
  in `ControlDispatcherTests` + `AppStoreOrganizationTests`/`AppStoreFocusTests` (the mutators, the
  enable-empty refusal, the restore prune, and the tree read-back) + CLI mapping in `CommandsTests` + the
  e2e `testWorkspaceFocusHidesOtherWorkspaces` in `ControlSidebarStatusUITests` plus `FocusWorkspaceUITests`.
  **The set landed as rook's OWN design, not as a take of upstream's.**
  Upstream (agterm `6722755a` and its follow-ups) shipped the same four legs — a multi-workspace set, an
  `add` mode, a UI toggle, and a snapshot migration — but redefines `focused` as membership, which we refuse
  for the reason above, so a cherry-pick was BANNED and every leg was re-derived against our three-field
  contract.
  Read the divergence as load-bearing when porting anything else from that series.
  `workspace.color` (target = workspace) tints that workspace's sidebar ICON — the positional arg is a
  `#rrggbb` hex or the literal `clear` (which, like an omitted color, resets it to the theme default),
  REUSING `ControlArgs.color` (no new arg) and validated by the shared `WatermarkConfig.isValidColorHex`
  in the dispatcher — an `invalid color (expected #rrggbb)` error that leaves the workspace UNCHANGED,
  pre-validated CLI-side by `validate()` too.
  UNLIKE the ephemeral `session.status --color` glyph tint, this one is PERSISTED
  (`Workspace.colorHex` → `WorkspaceSnapshot.colorHex`, an Optional field so an existing `workspaces.json`
  decodes with NO `Snapshot` version bump), so it survives a relaunch AND a close/reopen from Open Recent.
  It drives `AppStore.setWorkspaceColor` (delta-guarded, so a repeated set is a clean no-op), which
  persists through `scheduleSave()` rather than `save()` — the GUI half is a CONTINUOUS `NSColorPanel`,
  whose live drag would otherwise re-encode and rewrite the whole snapshot on every tick (the same reason
  `selectSession`/`setFontSize` debounce).
  Only the icon is tinted, never the row text: the tint is applied in `SidebarCellView.setColors`, the
  single choke point all four tint paths (cell build, `didAddSubview`, selection flip, theme change)
  re-assert through — a tint written anywhere else is clobbered by the next re-assert — and the row's
  `colorHex` is folded into `RowContent` so a change re-renders just that row.
  Its READ side is `ControlWorkspaceNode.color` on each `tree` workspace node (omitted when nil), so a
  script can record a workspace's color, change it, and restore it.
  GUI half: the workspace row's context menu — Color… (the system color panel, which previews live
  because it is continuous) and Reset Color (shown only when a color is set).
  There is deliberately NO menu-bar/palette entry: coloring is a per-row property, like Focus/Unfocus.
  Four-point keep-in-sync audit: (1) `case workspaceColor = "workspace.color"` in `ControlProtocol.swift`
  (reuses `ControlArgs.color`; adds `color` to `ControlWorkspaceNode`), (2) the `.workspaceColor` arm in
  `ControlDispatcher` (hex validation + the `clear` idiom) → `ControlActions.setWorkspaceColor`
  (app-side `ControlServer+Appearance`), (3) the `workspace color <#rrggbb|clear>` subcommand
  (`Color`, `validate()`-guarded) in `rookctlKit`, (4) round-trip + omit-when-nil in `ControlProtocolTests`
  + dispatcher validation in `ControlDispatcherTests` + `AppStoreAppearanceTests` (mutator, persistence,
  tree read-back, and the reopen-from-Recent round-trip) + `PersistenceTests` (legacy snapshot without
  the key) + CLI mapping in `CommandsTests` + the e2e `testWorkspaceColorSetAndClear` in
  `ControlSidebarStatusUITests`.
  `workspace.icon` (target = workspace) sets that workspace's sidebar ICON.
  The positional argument is CLASSIFIED by the host-free `WorkspaceIcon.kind(forRawIcon:)` — a path (it
  contains `/` or ends in a supported image extension), else a single emoji grapheme, else an SF Symbol
  name (dot-separated ASCII, so the three can't collide) — and the literal `clear` restores the default
  glyph.
  The split of validation follows the module boundary: the DISPATCHER owns the host-free half (the
  classification, the supported-format check, and `WatermarkConfig.isValidImagePath`), while the two checks
  that need the host live in `ControlServer+Appearance` — an SF Symbol name must RESOLVE
  (`NSImage(systemSymbolName:)`, else the icon would silently fall back to the default glyph while the
  command reported success — the `session.status --sound` precedent) and an image file must EXIST.
  An image is COPIED into `<stateDir>/workspace-icons/` (`WorkspaceIconStorage.install`, host-free
  Foundation) so the icon survives the user moving or deleting the original.
  Three rules make that storage correct, each fixing a real bug: install is IDEMPOTENT when handed a path
  already in the icons dir (the `tree` read-back hands a script the COPY's path, and feeding it back is the
  documented record-then-restore — without the short-circuit, source == destination and the copy would be
  deleted); the destination gets a FRESH name (`<workspaceID>-<8 hex>.<ext>`, not `<workspaceID>.<ext>` —
  a name derived from the id alone would make a swapped file produce an IDENTICAL spec, which the store's
  delta guard, the sidebar's `RowContent` diff, and the image memo would each swallow, so the command would
  report `ok` and show the old picture until relaunch); and the previous file is deleted ONLY on
  replace/clear, NEVER on `removeWorkspace` (a closed workspace reopens from the PERSISTED recent-closed
  list, so its icon must come back with it — deleting there would strip it).
  Rendering is `WorkspaceIconImage` (app target, memoized by spec): a symbol via the existing `rowIcon`
  factory, an image via `NSImage(contentsOf:)`, an emoji rasterized into an `NSImage`; anything that fails
  to resolve degrades to the default glyph rather than an empty row.
  **The workspace COLOR applies only to a TEMPLATE icon, decided by the PIXELS, not the extension**:
  a symbol always, and an image only when `WorkspaceIcon.isMonochrome(rgba:)` finds every visible pixel to
  be one color, since AppKit template rendering keeps only the alpha and repaints the rest in the tint.
  A colored image (of any format) and a color emoji carry their own colors — tinting those would paint over
  the picture, so the color is deliberately ignored there.
  Tinting every SVG on sight was the old rule and it was a bug: an SVG with an opaque background masked to
  a solid block of tint (an empty rectangle in the sidebar) and a multi-color one to a silhouette.
  Its READ side is `ControlWorkspaceNode.icon` + `iconKind` (`symbol`|`emoji`|`image`, both omitted when
  there is no custom icon), so a script can record the icon and restore it by feeding the value back.
  GUI half: the workspace row's context menu — Icon… (an `NSOpenPanel` limited to svg/png/jpeg) and Reset
  Appearance (clears icon + color), shown only when something is set.
  There is deliberately NO SF Symbol picker: no public API enumerates SF Symbols, so a GUI picker would
  mean hand-curating and maintaining a symbol list — symbols and emoji are the agent/CLI surface.
  Four-point keep-in-sync audit: (1) `case workspaceIcon = "workspace.icon"` + `ControlArgs.icon` +
  `ControlWorkspaceNode.icon`/`iconKind` + the host-free `WorkspaceIcon`/`WorkspaceIconStorage` in
  `rookCore`, (2) the `.workspaceIcon` arm in `ControlDispatcher` (classification + host-free checks) →
  `ControlActions.setWorkspaceIcon` (app-side `ControlServer+Appearance`: symbol/file checks + the copy),
  (3) the `workspace icon <symbol|emoji|path|clear>` subcommand (`Icon`, `validate()`-guarded, and it
  absolutizes a relative/`~` path since the app resolves it in ITS own cwd) in `rookctlKit`,
  (4) round-trip + omit-when-nil in `ControlProtocolTests` + dispatcher classification/rejection in
  `ControlDispatcherTests` + `WorkspaceIconTests` (the tint truth table, the classifier, and the storage's
  idempotence / fresh-name / delete-only-ours rules) + `AppStoreAppearanceTests` (mutator, file cleanup on
  replace, tree read-back, reopen-from-Recent) + `PersistenceTests` (a poisoned `icon.kind` decodes lossily
  to nil instead of wiping the tree) + CLI mapping in `CommandsTests` + the e2e
  `testWorkspaceIconSetAndClear` in `ControlSidebarStatusUITests`.
  `workspace.root` (target = workspace) sets that workspace's START DIRECTORY — the positional arg is a
  directory path or the literal `clear`/`--clear` (which, like an omitted path, resets it to nil).
  When set, EVERY new session created in that workspace opens in `root` — a HARD override of the global
  `newSessionDirectory` mode (home/currentSession/custom); when nil, new-session cwd falls through to the
  existing `AppSettings.resolveNewSessionCwd` logic unchanged.
  UNLIKE the ephemeral status tint, it is PERSISTED (`Workspace.root` → `WorkspaceSnapshot.root`, an
  Optional field so an existing `workspaces.json` decodes with NO `Snapshot` version bump), surviving a
  relaunch and a close/reopen from Open Recent.
  The path is stored VERBATIM (settable before the directory exists); a non-existent root is handled at
  SPAWN time app-side (`existingDirectory` falls back to the global logic / `$HOME`), so the host-free
  `resolveNewSessionCwd(workspaceRoot:currentSessionCwd:home:)` only CHOOSES the string, never touches the
  filesystem.
  Both new-session entry points consult it: the GUI `AppActions.resolvedNewSessionCwd(inWorkspace:)` (from
  `newSession()` + the sidebar row's New Session / `+`) and the control `makeSessionResponse`
  (`options.cwd ?? workspaceRoot ?? home`).
  Its READ side is `ControlWorkspaceNode.root` on each `tree` workspace node (omitted when nil), so a
  script can record a workspace's root, change it, and restore it.
  GUI half: the workspace row's context menu — Set Root Directory… (an `NSOpenPanel` directory picker)
  and Clear Root Directory (shown only when a root is set); no menu-bar/palette entry (per-row property,
  like Color/Focus).
  Four-point keep-in-sync audit: (1) `case workspaceRoot = "workspace.root"` in `ControlProtocol.swift`
  (reuses `ControlArgs.path`; adds `root` to `ControlWorkspaceNode`), (2) the `.workspaceRoot` arm in
  `ControlDispatcher` (the `clear`/empty → nil idiom) → `ControlActions.setWorkspaceRoot` (app-side
  `ControlServer+Appearance`), (3) the `workspace root <dir|--clear>` subcommand (`Root`, absolutizing a
  relative/`~` path like `Icon`) in `rookctlKit`, (4) round-trip + omit-when-nil in `ControlProtocolTests`
  + dispatcher routing in `ControlDispatcherTests` + `PersistenceTests` (disk round-trip + legacy snapshot
  without the key) + `AppStoreAppearanceTests` (tree read-back) + the deferred e2e (XCUITest).
  `tree` now also surfaces, on each `ControlSessionNode`, `foreground`/`splitForeground` — the LIVE foreground-process
  argv of the main + split panes (nil/omitted at the shell prompt), read through
  `ForegroundProcess.running(for:shellBasename:)` (`ghostty_surface_foreground_pid` → `sysctl(KERN_PROCARGS2)`
  → host-free `CommandRestore`/`ForegroundGroup`), populated in the tree builder per session so a script
  can read "what is each pane running".
  **`running` is NOT the restore capture, and the two must not be merged.**
  libghostty's foreground pid is `tcgetpgrp`, a process GROUP id: an interactive shell puts each job in
  its own group, so the leader IS the program — but a pane started with `--command` has no job-control
  shell, so its program sits in the group led by setuid-root `login`, whose argv `KERN_PROCARGS2` refuses
  for a non-root caller, and every such pane used to read as idle.
  `running` therefore DESCENDS the group to the first readable member (`ForegroundGroup.descentCandidates`,
  host-free + unit-tested) and strips the login dash from argv[0], while the restore capture
  (`ForegroundProcess.command`, `AppDelegate`'s save path) deliberately does NOT: a non-nil capture sets
  `hadForeground`, which preempts `initialCommand` in `CommandRestore.restorePlan`, so a descending
  capture would restore a `--command` session by TYPING its command into a login shell instead of taking
  the exec path — losing the `--wait` hold and close-on-exit.
  **Our OWN two extra callers were decided SEPARATELY, and they went opposite ways — on purpose.**
  They were left on `command` when `running` landed (upstream has no such call sites, so switching them was
  never part of that port); each was then judged on its own merits, and only one of them was a defect.
  - **`AgentMonitor` (the sidebar agent logo) now calls `running` — this WAS a defect.**
    A `--command claude` pane read as idle and wore the plain terminal glyph, the one pane shape where the
    logo is most wanted (a scripted agent pane nobody typed into).
    Measured: `login -flp <user> /bin/bash --noprofile --norc -c 'exec -l <cmd>'` leaves the program in
    login's group as login's direct child with argv[0] DASH-MARKED, and `KERN_PROCARGS2` on the setuid-root
    leader answers `EINVAL` for a non-root caller.
    So the dash strip is load-bearing here and not merely cosmetic: `AgentKind.classify` matches the argv[0]
    basename EXACTLY, so an unstripped `-claude` classifies as nothing — pinned by
    `ForegroundGroupTests.aDescendedCommandPaneClassifiesOnceTheLoginDashIsStripped`.
    The extra `sysctl` costs nothing in the steady state: the sweep's per-session pid cache keys on the
    group id, which does not change while the program runs.
  - **`isForeignAgent` deliberately STAYS on `command` — descending would flip a documented default.**
    It is fail-OPEN by design (see the `session.status --agentPid` section): an unprovable head PASSES, and
    a `--command` pane is unprovable precisely because the leader's argv is unreadable, so today its status
    reports are ACCEPTED.
    Descending would satisfy condition 2 (an agent at the head) and then FAIL condition 3, because the pid
    it compares is `foregroundPid()` — a process GROUP id, i.e. LOGIN's pid — while the hook's `claimed`
    (`AgentProcess.nearestAgentPid`) is the agent's OWN pid.
    Those can never be equal, so every status from the pane's own rightful agent would be silently dropped
    as foreign: a fail-CLOSED regression wearing the shape of a fix, and `ok: true` all the way, so nothing
    would ever surface it.
    Making the comparison descend TOO is a real design option, but it is new behavior with its own
    trade-offs (which member of the group counts as "the pane's agent"), not a debt payoff — a maintainer
    call, not a silent one.
    **That call was MADE on 2026-08-06: keep `command`, accept the hole.**
    The accepted cost is that a NESTED agent inside a `--command` pane can still drive that pane's row.
    The reasoning is which way each option FAILS: staying errs toward showing a status that is not ours,
    descending errs toward hiding a status that IS ours — and reaches that through a comparison that can
    never succeed.
    So this is CLOSED, not outstanding; do not re-open it as a defect.
    Reopen only as a deliberate feature, and only WITH the comparison and the dash strip below, together.
  - **A SECOND, independent layer already keeps that gate open on those panes, and it must be weighed with
    the first.**
    `AgentProcess.nearestAgentPid` classifies each ancestor's raw argv with NO dash strip, so the hook's own
    `-claude` ancestor does not classify and NO `agentPid` is reported at all — `isForeignAgent` then returns
    at its first guard, never reaching the foreground read.
    Teaching that walk to strip the dash would arm the gate on exactly the panes the paragraph above says it
    must not judge, so the two changes are one decision, not two.
  It ALSO surfaces `agent` on each node — the coding agent (`claude`/`codex`) detected in the session's
  FOCUSED pane, omitted when it runs anything else.
  This one is a READ-ONLY DERIVED field with NO write command, and that is a deliberate keep-in-sync
  EXEMPTION from the four-point audit (which governs WRITE actions): nothing SETS it — the app-side
  `AgentMonitor` observes it from the pane's foreground process (`ghostty_surface_foreground_pid` → `sysctl`
  → the host-free `AgentKind.classify`), so there is no state a script could write back.
  It is the CLASSIFIED form of the `foreground` argv already on the same node (which stays raw for anything
  the classifier doesn't recognize, so a mis-detection is always diagnosable from `foreground`), and the
  precedent is `foreground`/`title` — derived reads that likewise carry no command.
  It is also distinct from `status`: `agent` is what the pane RUNS (observed), `status` is what the agent
  REPORTS about its turn (`session.status`, driven by its hooks) — a session can carry one without the other.
  Populated in `AppStore.controlTree` from the ephemeral `Session.agentKind`, which the sidebar's agent logo
  renders (see [[sidebar]]); round-tripped by `treeSessionNodeRoundTripsWithAgent`/`…OmitsAgentWhenNil` and
  `AppStorePaneTests.controlTreeReportsAgentKind`.
  It ALSO surfaces `realized` on each node — the MAIN pane's `TerminalSurface.isRealized`, populated
  host-free in `AppStore.controlTree` (no app-side closure like the font sizes — `isRealized` is on the
  protocol) and FALSE rather than omitted for an empty slot, so only a server predating the field omits it.
  It exists because `session.new` answers `ok` for a model insert while libghostty refuses to create a
  surface with the display asleep, leaving a scheduled job's session unrealized until the displays wake (see
  [[libghostty]]); nothing in the tree separated that from a working session, and `fontSize` leaked it only
  as a side effect of the font read-back, ambiguous with a font size libghostty reports as zero.
  It is the MAIN pane because that is what `--command` spawns on and what `session.type`/`session.text`
  address by default; per-pane liveness stays with the `fontSize`/`splitFontSize`/`scratchFontSize` triple,
  so do NOT add a second per-pane spelling.
  Like `agent`/`foreground` it is a READ-ONLY DERIVED field with no write command, so it is keep-in-sync
  EXEMPT from the four-point audit.
  `rookctl tree` tags the row `(not realized)`.
  It ALSO surfaces `background` on each node — the `BackgroundWatermark` spec set via `session.background`
  (omitted when none), the read side of set/clear so a script can query the current watermark.
  It ALSO surfaces `overlaySizePercent` on each node — an OPEN overlay's size (`session.overlayActive ? session.overlaySizePercent : nil`
  in the tree builder): nil/omitted = the full-pane overlay OR no overlay (so gate on `overlay` first),
  else the floating panel's percent (1...100).
  It is the READ side of `session.overlay.resize` (which had only the write side), so a tmux-style zoom
  script can record the current size before switching to `--full` and restore the EXACT original on un-zoom
  (not a guessed default).
  It ALSO surfaces `hasSplit` on each node — whether the session HAS a split pane at all, shown or hidden
  (`session.hasSplit ? true : nil` in the tree builder), omitted when there is none.
  `split` alone was ambiguous: a split hidden with ⌘D reads `split: false` while `splitRatio`/`splitFocused`
  describe a pane the boolean says is not there, so a script filtering on `split` missed a live shell.
  `hasSplit` is present exactly when those two can be, which is what makes them readable without
  second-guessing `split`.
  It ALSO surfaces `splitRatio` on each node — the left-pane divider fraction of a session that HAS a split
  (`session.hasSplit ? session.splitRatio : nil` in the tree builder, so shown OR hidden splits report it),
  nil/omitted when there is no split or the ratio was never explicitly set (divider then at the default 0.5).
  It is the READ side of `session.resize` (whose applied ratio was echoed ONLY on the resize call's own
  `ControlResult.ratio`), so a script can record the current ratio before maximizing a pane and restore the
  exact divider even if the USER dragged it.
  It ALSO surfaces `splitFocused` on each node — which pane holds focus in a session that HAS a split
  (`session.hasSplit ? session.splitFocused : nil` in the tree builder, so shown OR hidden splits report it):
  `true` = the split (right) pane, `false` = the main (left) pane, nil/omitted when there is no split.
  It is the READ side of `session.focus` (write-only), so a script can record which pane was focused and
  restore it via `session.focus --pane left|right` (a `false` is emitted, distinct from the nil no-split
  case — the left pane being focused is real state).
  `tree` ALSO carries, at the TOP level (alongside `idleMs`/`autoFollowMs`), `sidebarVisible` — the read
  side of the write-only `sidebar` command (per-window sidebar visibility), populated LIVE from the
  projected window's store in `AppStore.controlTree`.
  The SAME field also rides each `ControlWindowNode` on `window.list` (read from `stores[id]?.sidebarVisible`,
  omitted for a closed window), so a script can enumerate every window's sidebar state.
  BUT `window.list` is served from the background-thread `cachedWindowNodes` cache
  (refreshed after every dispatched command + on frontmost change), and a GUI-only ⌃⌘S toggle is neither —
  so `AppStore.setSidebarVisible` posts `.rookSidebarVisibilityChanged` (rookCore) and `ControlServer`
  observes it to `refreshWindowCache`, keeping the cached `sidebarVisible` honest.
  A script that reads-then-acts (e.g. the tmux-style zoom that must restore the sidebar only if it was
  visible) should still prefer `tree`'s LIVE `sidebarVisible` over the cached `window.list` one — the tree
  is built on the main actor per request, so it can never lag.
  Each `ControlWindowNode` ALSO carries `geometry` — the open window's live on-screen frame
  (`ControlWindowFrame{x, y, width, height, display}`, omitted for a closed window with no NSWindow).
  It is the READ side of the write-only `window.move`/`window.resize` (which set the frame but nothing
  reported it), in the SAME coordinate system those accept: `x`/`y` are the top-left relative to `display`
  (y down), `width`/`height` the frame size, so a read-back round-trips straight back through
  `window.move`/`window.resize` (record → resize/move → restore the exact frame).
  Because the frame lives in AppKit (`WindowLibrary` is host-free), `controlWindowNodes` takes an app-side
  `geometry:` closure (default nil for tests) that `ControlServer.buildWindowList` fills from
  `WindowRegistry.geometry(for:)` — the exact inverse of `move`'s forward math.
  It rides the `cachedWindowNodes` cache (there is no LIVE tree copy — geometry is window-scoped, absent
  from the session tree), and since a user drag/resize/zoom/fullscreen changes it with NO control command
  AND a polling `window.list` is fast-path-served (so it never refreshes its own cache), `ControlServer`
  observes the NSWindow `didMove`/`didResize`/`didEnterFullScreen`/`didExitFullScreen` notifications and
  `refreshWindowCache`s on each (the fullscreen ones fire AFTER the async transition, so the settled
  `styleMask` is captured) — mirroring the `.rookSidebarVisibilityChanged` refresh for the GUI-only
  sidebar toggle, so the read-back stays current.
  The notification is IGNORED, not captured — a non-Sendable `Notification` can't cross into the
  `MainActor.assumeIsolated` block under Swift 6 strict concurrency (the `sending 'note'` error), so the
  refresh fires for ANY window rather than filtering to a rook one; harmless, since a non-rook panel
  just rebuilds the same cheap rook nodes.
  The host-free plumbing (the closure + node field) is unit-tested (`controlWindowNodesIncludeGeometryFromClosure`,
  the round-trips); the coordinate conversion + the NSWindow-notification cache refresh are app-side, build-verified.
  Each `ControlWindowNode` ALSO carries `fullscreen`/`zoomed` — the read side of the write-only
  `window.fullscreen`/`window.zoom` toggles (so a script can toggle idempotently), filled by a PARALLEL
  app-side `flags:` closure on `controlWindowNodes` (kept separate from `geometry:` so each stays a clean
  addition) that `buildWindowList` reads from `WindowRegistry.windowFlags(for:)`
  (`styleMask.contains(.fullScreen)` / `NSWindow.isZoomed`); both nil/omitted for a closed window, on the
  cache like `geometry`. The closure plumbing is unit-tested (`controlWindowNodesIncludeFullscreenZoomFromClosure`
  + the round-trips); the NSWindow reads are app-side, build-verified.
  `window.minimize` parks a window in the Dock or brings it back — the control half of ⌘M / the yellow
  traffic light / the Minimize title-bar double-click, and the last gap in the window surface (a script
  could move/resize/zoom/fullscreen but neither park a window nor ask whether it was parked).
  `args.mode` is the shared `ControlToggleMode` vocabulary `on`|`off`|`toggle`, with **toggle the explicit
  default** (an omitted mode is sent as `toggle` by the CLI; an unparseable one is an
  `invalid window minimize mode: X` error).
  `on`/`off` resolve against the window's CURRENT `isMiniaturized`, so they are idempotent and only `toggle`
  flips; `WindowRegistry.minimize` returns a three-way `MinimizeOutcome` so the arm can distinguish
  `window not open — window.select it first` from `cannot minimize a full-screen window — window.fullscreen
  it first`.
  **The full-screen case is an ERROR rather than a silent ok on purpose**: AppKit no-ops `miniaturize` on a
  natively full-screen window, so reporting success would be a lie.
  (It fires only when the state would actually CHANGE — the idempotent short-circuit runs first, so
  `window minimize off` on an already-restored full-screen window is a plain ok.)
  Miniaturize/deminiaturize are ANIMATED, so the arm settle-polls `isMinimized == desired` before replying;
  without it the `defer`-ed window-cache refresh would capture the OLD value and the very next
  `window.list` would report the state the caller just changed away from.
  Parking the FRONTMOST window also hands `frontmostWindowID` to a still-visible one (`handOffFrontmost`):
  `activeWindowID` falls back only when the window's STORE is gone and a minimized window keeps its store,
  so otherwise every untargeted command would keep routing into a window sitting in the Dock — and AppKit
  keys another window on a minimize only while the APP is active, which is never the case for a script
  parking windows in the background.
  With every open window minimized there is nothing to hand to, so the pointer stays put rather than being
  cleared.
  `window.new --minimized` (`ControlArgs.minimized`) creates the window and THEN parks it, so a script can
  build a set of project windows without each one flashing on screen and stealing focus; it waits out
  `WindowAccessor`'s deferred second present before minimizing (that present deminiaturizes, so parking on
  the instant of registration would simply be undone), then hands frontmost off — and only when the park
  actually applied, since an unparked window is visible and owes nothing.
  The READ side is `ControlWindowNode.minimized` on `window.list` (nil/omitted for a closed window), which
  is what makes record-then-restore possible.
  It rides the `cachedWindowNodes` cache like `geometry`/`fullscreen`/`zoomed`, so the new
  `didMiniaturize`/`didDeminiaturize` observers (plus `.rookWindowAttachmentChanged` on register/unregister)
  refresh it — otherwise a ⌘M or a Dock click, which run no control command, would leave the cache lying.
  **A minimized window still reports its `geometry`** — the frame it will come back to — because
  `WindowRegistry.resolvedScreen` falls back to the display the frame overlaps most when `NSWindow.screen`
  goes nil off-screen, so record-then-restore works in the parked state too.
  CLI: `rookctl window minimize [id] [on|off|toggle]` — BOTH positionals are optional, so a bare
  `window minimize on` would bind `on` to the id; the subcommand recovers the intent because a window
  address is a UUID prefix (hex only) or `active` and can never be a mode word.
  Four-point keep-in-sync audit: (1) `case windowMinimize = "window.minimize"` + `ControlArgs.minimized`
  + `ControlWindowNode.minimized` in `ControlProtocol.swift` (`window.minimize` reuses `ControlArgs.mode`),
  (2) the `.windowMinimize` dispatcher arm (mode parse) → `ControlActions.windowMinimize` + the widened
  `windowNew(name:minimized:)`, app-side in `ControlServer+WindowCommands.swift` over
  `WindowRegistry.minimize`/`isMinimized`, plus the `flags:` closure feeding the node,
  (3) the `window minimize` subcommand + `window new --minimized` in `rookctlKit`,
  (4) round-trip + omit-when-nil in `ControlProtocolTests` + dispatcher validation in `ControlDispatcherTests`
  + `WindowLibraryTests` (the node plumbing) + CLI mapping in `CommandsTests`.
  The port also fixed four pre-existing plumbing defects the minimize path exposed, all worth knowing
  because they silently mis-routed commands: `window.new` replied BEFORE its NSWindow attached (an immediate
  `window.resize`/`move`/`zoom` on the new id failed with `window not open` — it now polls
  `WindowRegistry.isRegistered`, NOT `library.isOpen`, which `newWindow()` sets synchronously and which
  would prove nothing); `window.list` served a cache nothing refreshed on window ATTACH, so a brand-new
  window reported no geometry; and `window.select` never took frontmost while the app was INACTIVE —
  `frontmostWindowID`'s only writer was `reportFrontmost` on key/main notifications AppKit does not deliver
  to an inactive app, so a background `window select` replied ok while every later untargeted command kept
  routing into the previously-active window (`takeFrontmost` is the control-path equivalent).
  A fourth was ours, not upstream's: `WindowAccessor.bringForwardForUITests` armed six deferred presents on
  EVERY window attach and latched on only one branch, dragging a `window.new --minimized` back out of the
  Dock.
  Relatedly, `session.reveal` now RAISES the owning window: `makeFirstResponder` does not, and the
  notification handler's `NSApp.activate` brings the APP forward, not a window parked in the Dock — so a
  banner click into a minimized window used to change the selection invisibly.
  `restore.clear` clears every open session's saved CAPTURED foreground command (`Session.foregroundCommand`/`splitForegroundCommand`)
  and persists via `library.saveAllOpen()`, so the next restart restores plain shells for those panes instead
  of re-running the captured commands (also closing the force-quit re-fire: the restored command is consumed
  in memory but its on-disk copy lingers until the next save, which a force-quit skips).
  It does NOT clear a `session.new --command` session's own `initialCommand` (the durable creation identity),
  which still re-runs on restore when the setting is on — `restore.clear` is scoped to captured foreground
  commands only.
  App-global like `keymap.reload` (clears all open windows, no `--window`).
  Four-point keep-in-sync audit for `restore.clear`: (1) `case restoreClear = "restore.clear"` in `ControlProtocol.swift`
  (no target/args; `foreground`/`splitForeground` added to `ControlSessionNode`),
  (2) the `.restoreClear` dispatcher arm → the app-side `ControlActions.clearRestoreCommands` + the foreground population
  in the tree builder, (3) the `restore clear` subcommand (`Restore`) in `rookctlKit`,
  (4) round-trip (`restoreClearRoundTrips` + `treeSessionNodeRoundTripsWithForeground`/`…OmitsForegroundWhenNil`)
  in `ControlProtocolTests` + the e2e (`testTreeExposesForegroundProcess`,
  `testRestoreClearSucceeds`) in `ControlAPIUITests`.
  `session.background` (target = session) sets or clears a per-session background composited behind the
  terminal grid — `args.mode` is `image`/`text`/`color`/`clear`.
  `image`/`text` are watermarks driven by libghostty `background-image*` keys:
  `image` needs `args.path` (PNG/JPEG, validated for format + existence + no control chars in the path),
  `text` needs `args.text` (capped at 256 chars; + optional `args.color` #rrggbb, default the terminal
  foreground), and both accept `args.opacity` (0...1)/`args.fit`/`args.position`/`args.repeats`.
  `color` is a SOLID terminal background color driven by the `background` key: it needs `args.color` (#rrggbb)
  and takes NO per-call opacity — it is drawn at the Settings WINDOW translucency (solid when off),
  emitted as `background-opacity = <windowOpacity>` at apply time so the color honors the user's opacity/blur
  instead of forcing itself opaque (unlike the image/text watermark, which pins `background-opacity = 1`
  so the image shows).
  opacity/color/fit/position validated against the shared host-free `WatermarkConfig`,
  used by BOTH the CLI `validate()` and the server.
  The `BackgroundWatermark` spec (host-free, `Codable`) is persisted in `SessionSnapshot` (survives restart)
  via `AppStore.setBackgroundWatermark`, then applied to the session main + split + scratch surfaces as a
  PER-SURFACE ghostty config overlay (the scratch reaches it through `watermarkSession`, see `session.scratch`
  above — the re-apply loop in `ControlServer+SurfaceIO.applyWatermark` covers all three, so a background set
  while the scratch is already open reaches it):
  `GhosttyApp.configWithOverlay` builds the same base files + an overlay file
  (`WatermarkConfig.overlayText`: for image/text the `background-image*` lines + `background-opacity = 1`
  so the image shows even under window translucency, which pins the global `background-opacity` to 0;
  for `color` a `background = <hex>` line + `background-opacity = <windowOpacity>` (passed in from
  `GhosttyApp.shared.windowOpacity`) so the color honors translucency instead of forcing itself opaque;
  plus a `font-size` line so the per-session cmd-+/- zoom is not reset by the push), and `GhosttySurfaceView.applyWatermarkFromSession`
  calls `ghostty_surface_update_config`, RETAINING each per-surface config in `ownedConfigs` and freeing
  it only on surface teardown (safe — the consumer is gone — unlike the never-freed app-wide config).
  libghostty auto-fits the image to the surface and RE-FITS on resize (no app-side resize code);
  a `.text` watermark rasterizes to a PNG under `<stateDir>/watermarks/<sessionID>.png` via the app-side
  `WatermarkRenderer` (AppKit; default tint = the live terminal foreground), regenerated on restore +
  cleared on `clear`, on `text`→`image` switch, and on permanent session/workspace/window removal.
  A global `config.reload`/settings change broadcasts the SHARED config (no image) to every surface via
  `applyConfig`, WIPING any watermark — so `GhosttyApp.reloadConfig` re-resolves the theme colors and
  then calls `reapplyWatermarkIfNeeded` on each surface AFTER the broadcast to re-assert it (the theme
  colors first, so a default-tinted `.text` watermark re-renders with the new foreground, not the old).
  A `.color` background bakes the window opacity into its `background-opacity` at apply time, so it must
  RE-TRACK the Settings translucency slider: `SettingsModel.apply` re-asserts every `.color` surface
  (`GhosttySurfaceView.reapplyColorBackgroundIfNeeded`, guarded to `.color` so image/text aren't rebuilt
  per tick) right AFTER `applyWindowTranslucency` updates `GhosttyApp.windowOpacity`, on any opacity
  change — the `reloadConfig` re-assert alone reads a STALE opacity (it runs before the update) and a
  within-range drag doesn't reload at all, so neither path alone keeps a color session tracking the slider.
  `BackgroundWatermark.fit`/`position` are typed `Fit`/`Position` `CaseIterable` enums (like `Kind`), not
  raw `String` — the raw values match ghostty's keys so they serialize identically, and a bad value can't
  reach a config line (`imagePath`/`colorHex` stay free text, re-validated on emit by `overlayText`, closing
  the restore-path injection as defense-in-depth). The spec is READ back on each `tree` node's `background` field.
  Four-point keep-in-sync audit for `session.background`: (1) `case sessionBackground = "session.background"`
  + `ControlArgs.path`/`color`/`opacity`/`fit`/`position`/`repeats` in `ControlProtocol.swift` (+ `background`
  on `ControlSessionNode` for the read-back),
  (2) the `.sessionBackground` dispatcher arm — `ControlDispatcher.dispatchSessionBackground` validates + builds the spec,
  the app-side `setSessionBackground` does the filesystem checks (`isSupportedImage`/`fileExists`) + `applyWatermark`
  to the realized surfaces (+ `background:` populated in the tree builder), (3) the
  `session background image|text|color|clear` subcommands in `rookctlKit` (shared opacity/color/fit/position
  `validate()`; `color` takes color only, no opacity), (4) round-trip in `ControlProtocolTests` (incl.
  `treeSessionNodeRoundTripsWithBackground` + `backgroundWatermarkColorKindSerializes`)
  + `WatermarkConfigTests` (incl. the `color*` overlay cases) + `WatermarkStorageTests` + `CommandsTests`
  (CLI parse + bad-arg rejection) + the e2e `testSessionBackgroundSetClearAndValidation` in `ControlAPIUITests`
  (image/text/color set/clear + tree read-back).
  **Agent-skill mirror (HARD keep-in-sync, 4th surface):** all commands are documented in the bundled
  `rook/Resources/agent-skill/` (SKILL.md summary, reference.md detail,
  examples.md recipes) and the command count there is kept in step with the catalog above — do not restate
  the number here, one place to update is enough.
