---
name: rook
description: >
  Drive rook, a native macOS terminal app, programmatically via its rookctl CLI and a local
  control socket. Use when running inside a rook session and asked to control the terminal:
  create, rename, close, select, or reorder sessions and workspaces; split panes; toggle the
  per-session scratch terminal; open or close overlay terminals and read their exit status; post a
  passive HUD message panel over a session while the user keeps typing; ask the
  user to choose from a native fuzzy picker and read back their answer; display
  an image inline via a bundled helper script; render a Markdown file (a plan, a README) in the
  session's built-in preview panel; type
  into a session, copy its selection, or search its scrollback; post desktop notifications; manage windows (new, list,
  select, close, resize, move); change font size; or reload and edit the keymap and the rook-scoped
  ghostty config. Also covers subscribing to app events (agent-status transitions, delivered
  notifications, session created/closed, tree changes) with `rookctl events` / `events.read`, the
  window/workspace/session addressing model and the ROOK_* environment a spawned shell sees, plus
  diagnosing problems (keymap editor, custom actions, logs) and filing a bug as a GitHub issue or a
  feature request / question as a GitHub Discussion.
when_to_use: >
  Trigger on: rook, rookctl, rook control socket, session.new, session.close, session.type,
  session.split, session.scratch, session.filetree, session.markdown, markdown preview, session.focus, session.resize, surface.zoom, dashboard, pick, pick.open, pick.result, pick.cancel, native picker, ask the user to choose, session.go, session.copy, session.paste, session.selectall, session.text, session.search, session.status, session.agent, resume agent conversation,
  session.flag, session.seen, session.reveal, session.background, session.overlay,
  session.hud, hud panel, show a message over a session, workspace.new, workspace.select, workspace.move, workspace.focus, workspace.focus add, workspace focus set, add a workspace to the focus set, workspace.filter, workspace focus filter, re-apply the workspace filter, workspace.root, workspace.collapse, workspace.expand, window.new, window.list,
  window.select, window.resize, window.move, window.zoom, window.fullscreen, window.minimize, quick terminal, sidebar, sidebar.mode, sidebar.expand, sidebar.collapse, flagged, notify, font.inc, keymap.reload, keymap.list, config.reload,
  theme.set, theme.list, select theme, edit keymap, show an image, display an image inline, show-image,
  events, events.read, rookctl events, event subscription, subscribe to events, watch rook events,
  event cursor, tree.changed,
  ROOK_SESSION_ID, ROOK_SOCKET, and asks to drive or script rook. Also: troubleshoot rook,
  keymap editor won't open, custom action / custom command not working, rook logs, file a rook
  bug, report a rook issue, open a rook discussion / feature request.
allowed-tools: Bash(rookctl *)
---

<!-- rook-skill -->

# Driving Rook

Rook is a native macOS terminal. It exposes a programmatic control channel over a local unix
socket, driven by the companion CLI `rookctl`. Use it to build and steer terminal layouts, run
programs in overlays, type into sessions, and notify the user in the exact session you are working
in. Every command is request/response — one request per invocation — and terminal OUTPUT is never
streamed (read a buffer on demand with `session text`). Events, on the other hand, ARE subscribable:
`rookctl events` follows a cursor over the app's event ring and reports agent-status transitions,
delivered notifications, sessions created/closed, and structural `tree.changed` signals, so you no
longer have to poll `tree --json` and diff snapshots.

## Am I inside Rook?

Each shell Rook spawns gets these environment variables. Check `ROOK_ENABLED` before assuming
the control channel is available:

- `ROOK_ENABLED=1` — this shell runs inside rook.
- `ROOK_SESSION_ID` — the current session's UUID (the session this shell belongs to).
- `ROOK_WINDOW_ID` / `ROOK_WORKSPACE_ID` — the owning window / workspace UUIDs.
- `ROOK_SOCKET` — the absolute path to the control socket this app bound. A second instance that found the
  path already owned advertises `<socket>.unavailable` here, which never connects: that is the diagnosis for
  a connection refused against a path ending in `.unavailable`.
- `ROOK_PANE` — which pane this shell runs in: `left` (main), `right` (split), or `scratch`. It is the
  shell's ROLE at spawn time and can go stale (a split survivor promoted into the main slot keeps its
  baked `right`); unset in an overlay and in the quick terminal.
- `ROOK_PANE_ID` — an opaque, STABLE per-surface token for the same pane. Unlike `ROOK_PANE` it never
  goes stale: the app resolves it against the session's live surfaces to get the pane's CURRENT slot.
  The agent-status hook forwards it as `session status --pane-id`; scripts normally just leave it alone.

Every spawned shell also identifies its host terminal as `TERM_PROGRAM=rook` (with the app version in
`TERM_PROGRAM_VERSION`), overriding the `ghostty` identity embedded libghostty would otherwise report.

The quick terminal is scratch (not in the tree), so it only gets `ROOK_ENABLED`, `ROOK_WINDOW_ID`,
and `ROOK_SOCKET` (no session/workspace ids).

These variables are inherited by every process the session's shell spawns — including long-lived
daemons that outlive the shell. A tmux/screen server, a session manager (agent-deck and the like), or
any background service started from inside a session captures the spawning session's `ROOK_*` and
passes it to every child it ever creates, so status hooks running in those children resolve
`$ROOK_SESSION_ID` to the session that happened to start the daemon and report to the WRONG session.
Before starting such a process from inside Rook, scrub the variables
(`env -u ROOK_ENABLED -u ROOK_PANE -u ROOK_PANE_ID -u ROOK_SESSION_ID -u ROOK_SOCKET -u ROOK_WINDOW_ID -u ROOK_WORKSPACE_ID <cmd>`);
see troubleshooting.md ("agent-status glyph updates the wrong session") for diagnosing and fixing an
already-poisoned tmux server.

## Running rookctl

`rookctl` must be on PATH (install it from Rook's **Help ▸ Install Command Line Tool…**). If it
is not on PATH, the user can install it, or you invoke it by absolute path.

- The socket path auto-resolves; usually no `--socket` is needed. To be explicit, pass
  `--socket "$ROOK_SOCKET"`.
- `--socket` and other options go **after** the subcommand: `rookctl tree --json`, not
  `rookctl --json tree`.
- Add `--json` to any command to get the raw JSON response (machine-readable). Without it, ordinary
  mutations print `ok`, batch close/move prints the affected session count, and `tree`/`list` print a
  human listing.
- One request per invocation. Mutating commands return the affected/new id; batch session mutations return
  the number actually changed. Create commands (`session new`, `workspace new`, `window new`) print the new id.

## The model

A **window** is the top level: a named bundle rendered in its own on-screen macOS window. Each window
holds a tree of **workspaces**, each holding **sessions**. A session has a primary shell and can also
have: a **split** pane (a second shell side by side), a **scratch** terminal (a third full-coverage
shell, toggled like the split), and an ephemeral **overlay** (runs one program on top, then vanishes).
The same session-wide slot also holds a **HUD** (`session hud`), a small passive panel carrying a message
instead of a program: the session keeps focus and stays typable under it. One slot, so a session shows
either a HUD or a program overlay, never both.
Separately, each window has one **quick terminal** (a scratch overlay at 90% of the window, not part
of the tree).

Inspect the live tree any time with `rookctl tree --json` (workspaces → sessions, each with
`id`, `name`, `cwd`, `title`, `active`, `split`, `overlay`, `hud`, `scratch`, `status`, `background`, `shell`, `surfaces`).
`shell` is the session's shell path, omitted when it runs the app's default — the read side of
`session new --shell`, persisted, so a script can re-create a session in the same shell. `title` is the raw OSC
terminal title (e.g. a remote host over SSH), omitted when none was reported — read it when a
session's local `cwd` is stale because it's connected to a remote. `surfaces[].id` is the
control address for `surface zoom` (`left`, `right`, `scratch`, or `overlay`), including
hidden-but-alive split/scratch surfaces. The tree object also carries six
read-only top-level fields: `idleMs` (ms since the last user input in the window), `autoFollowMs`
(the Auto-follow timeout in ms, omitted when Disabled), `sidebarVisible` (whether the window's
sidebar is currently shown — the read side of the write-only `sidebar` command), `sidebarMode`
(`tree` or `flagged` — the read side of `sidebar mode`), `quickVisible` (whether the window's quick
terminal is shown — the read side of the write-only `quick` command), and `workspaceFilter` (whether
the sidebar's workspace focus filter currently applies — the read side of `workspace filter`, whose
MEMBER half is each workspace node's `marked`, with the invariant
`focused == marked && workspaceFilter`). List windows with
`rookctl window list --json`; each window also reports `autoFollowMs`, `sidebarVisible`, `geometry`
(the live frame `{x, y, width, height, display}` in the units `window move`/`window resize` take — the
read side, so record it then restore the exact frame), `fullscreen`/`zoomed` (the read side of
`window fullscreen`/`window zoom`, so a script can make those toggles idempotent), and `minimized`
(whether the window sits in the Dock — the read side of `window minimize`; a minimized window still
reports its `geometry`, so record-then-restore works while it is parked) — all omitted for a
closed window, but not the live `idleMs`, which is `tree`-only.

## Addressing

Commands that target a session or workspace take `--target` (default `active`):

- `active` — the selected session / current workspace.
- a full UUID (case-insensitive), or a unique **prefix** of one (git-style). Zero matches → `notFound`
  error; two or more → `ambiguous` error listing candidates.

`window.*` commands take the window id/prefix/`active` as a positional argument. Other commands accept
a global `--window <id|prefix|active>` to operate on a specific window's tree (default: the frontmost).

Scripts rarely type ids: create with `*.new` (capture the returned id), or act on `active`.

**Agents: `active` is almost never your own session.** `active` is the session the USER has selected in
the GUI; your shell runs in `$ROOK_SESSION_ID`, and the user is usually on a different session while
you work. For any session-scoped command meant to act on *this* session — `overlay open`, `scratch`,
`type`, `text`, `background`, `status`, `copy`, … — pass `--target "$ROOK_SESSION_ID"`. Omit it and
you open overlays / type into whatever the user has selected, not your own session.

## Command summary (80 commands)

Run `rookctl <area> <cmd> --help` for exact flags. Full detail in **reference.md**; recipes in
**examples.md**. (The count excludes `debug.appearance`, a UI-test-only seam with no `rookctl`
subcommand — don't re-derive the number from the raw `Command` enum, which has one case more.)

**tree** — print the workspace/session tree (`--json` for structured). Each session node carries
`foreground`/`splitForeground` (the live argv of each pane's foreground process, omitted when the pane
is at its shell prompt) — i.e. what each pane is currently running — `agent` (the coding agent detected in
the focused pane: `claude`|`codex`, omitted otherwise — observed from the process, not reported by the
agent, and distinct from `status`, which the agent's own hooks set), `agentSession`/`splitAgentSession`
(the agent CONVERSATION each pane is on — `{kind, id, configDir?}` — as that agent's own hook reported it
via `session agent`, omitted when none was reported; the read side of that write-only command, and
distinct from `agent`, which is merely WHICH agent runs there), `status` (the agent-status set
via `session status`: `active`|`completed`|`blocked`, omitted when idle), `statusPane` (which pane set
that status: `left` (main) | `right` (split) | `scratch`, from `session status --pane`, omitted when
unset or idle), `statusBlink`/`statusColor`/`statusShape` (the status glyph's `--blink` flag, its `--color` `#rrggbb`
override and its `--shape` silhouette from `session status`, omitted when idle / not blinking / default
color / default semantic glyph), `background` (the background
spec — image/text watermark or solid color — set via `session background`, omitted when none — the read side of set/clear),
`unseen` (the unseen-notification badge count — raised by `notify`/OSC 9/777, cleared by `session
seen` — omitted when zero), `overlaySizePercent` (an open overlay's floating-panel percent 1–100,
omitted for a full-pane overlay or no overlay so gate on `overlay` first; the read side of `overlay
resize` for a record-then-restore zoom),
`hud` (the message panel occupying the session-wide slot — `{message, detail?, spinner, backgroundColor?,
sizePercent?, heightPercent?, position}`, the two percents being the panel's width and height shares —
omitted when none is up; the read side of `session hud`. `position` and `spinner`
always report the EFFECTIVE value, `center` and a static panel's `none` included, so a caller who omitted
them never has to know the defaults; `spinner` names the STYLE, so `none` is what a caller echoes back to
turn one off. While a HUD is up the node's `overlay` reads `false` and `overlaySizePercent` is omitted, so a
poll for "is a program covering this session" cannot mistake a message for one; HUD state is poll-only,
no event announces it),
`splitRatio` (the left-pane divider fraction 0.05–0.95 of a
session that has a split — shown or hidden; omitted when there's no split or the ratio was never set (at
the default 0.5) —
the read side of `session resize`, record it to restore the exact divider), `splitFocused`
(which pane holds focus in a session that has a split — `true` = split/right, `false` = main/left; omitted
when there's no split; the read side of `session focus`, record it to restore focus), `fileTreeVisible` (whether the
session's file-tree panel is shown — the read side of `session filetree`), `fileTreeRoot` (the
directory the panel is currently rooted at — set by `session filetree reroot <path>` (or `refresh`,
which roots at the cwd); omitted when the panel is hidden — the read side of `session filetree reroot`),
`markdownPath` (the Markdown file the session's preview panel is rendering — an absolute path, omitted
when the panel is closed, so its presence IS the panel's visibility — the read side of `session
markdown`), and `surfaces` (`id`, `kind`, `active`, `visible`) for `surface zoom`. The tree top level carries `zoomedSurface`
(the control id of the currently zoomed surface, omitted when nothing is zoomed — the read side of
`surface zoom`, so a script can check the zoom state and record-then-restore). It also carries the read
side of the `dashboard` command (all omitted when no dashboard is open): `dashboardMembers` (the pane refs
the open dashboard shows, in grid order — `<session-id>:left` for a primary pane, `<session-id>:right` for
a split pane, so a split session appears as both), `dashboardHighlighted` (the highlighted cell's pane ref —
the one Enter jumps into, focusing that exact pane), `dashboardFontSize` (the absolute font size in points
applied to the cells, omitted when untouched), and `dashboardFontMode` (`auto`|`fixed`|`untouched`).
Finally it carries `pickPending` (the id of the picker currently waiting for the user's answer in that
window, omitted when none — the read side of `pick open`, so a script can tell whether a question is
already on screen before opening another).

**events** — `events [--json] [--kind K] [--limit N] [--run UUID --after SEQ]` — follow the app's
event ring instead of polling `tree`. The CLI is a poll loop over the one-shot `events.read` command
(it sleeps 250 ms only after an EMPTY page, so a burst drains at full speed) and prints one line per
event: a human column layout, or one bare JSON object per line with `--json` (NDJSON — pipe it to
`jq`). Kinds are `status` (an agent-status transition, with the same `status`/`pane`/`blink`/`color`
values `session status` writes), `notify` (a notification accepted for a session — `title` + `body`,
from the terminal's own OSC 9/777 as well as the `notify` command, and recorded even when banner display
is off), `session.created`, `session.closed`, and
`tree.changed` (a debounced per-window structural change). Starting with NO cursor subscribes FROM
NOW — there is no history replay. The ring is bounded (4096 entries) and lives only for one app run,
so a cursor that is stale, from a previous run, or ahead of the sequence FAILS loudly rather than
silently re-anchoring; see **reference.md ▸ events** for the exact error strings and the cursor
contract.

**workspace** — `new [name] [--collapsed]` (`--collapsed` creates it already closed in the sidebar, so a
script can fill it with `session new --no-select` without it popping open) ·
`rename <name>` · `delete` · `select` · `move --to up|down|top|bottom` ·
`focus [on|off|toggle|add]` (edit the sidebar's focus SET — the workspaces the filter narrows the tree
to. Each mode does two separable things, to the SET and to the filter FLAG: `on` marks this workspace
ALONE (replacing the set) and APPLIES the filter; `add` marks it alongside the existing members and
leaves the flag exactly as it was; `off` is the REMOVE mode — it unmarks this workspace, and the flag
switches off only once the set empties; `toggle` (the default) replace-toggles, clearing everything when
this workspace is the only marked one AND the filter applies, else behaving like `on`. There is no
`remove` token (that is `off`) and no membership-toggle mode. Build a working set with N × `focus add`
and apply it with ONE `filter on` — an `add` never applies the filter, so the whole tree stays on screen
while you pick. Read membership back from the workspace node's `marked` and the EFFECTIVE focus from its
`focused`) ·
`filter [on|off|toggle] [--window W]` (apply or lift the filter WITHOUT changing the SET — the way back
after an involuntary jump (idle auto-follow, attention nav, a notification reveal) switched it off;
window-scoped, so it takes no `--target`; read back from the tree's top-level `workspaceFilter`) ·
`color <#rrggbb|clear>` (tint the workspace's
sidebar icon; persisted, read back from the tree workspace node's `color`) ·
`icon <symbol|emoji|path|clear>` (set the workspace's sidebar icon — an SF Symbol name like `hammer.fill`,
a single emoji, or a path to an svg/png/jpeg, which is copied into the state dir; read back from the tree
workspace node's `icon` + `iconKind`. The color applies only to a symbol or a monochrome image — a colored
image and an emoji keep their own colors) ·
`root <dir|clear>` (set the workspace's ROOT directory — new sessions of that workspace open there (a hard
override of the global new-session-directory setting; a stale/removed dir falls back to it), persisted, read
back from the tree workspace node's `root`) ·
`collapse` / `expand` (close or open ONE workspace's row in the sidebar tree — the per-workspace analogue
of `sidebar collapse`/`sidebar expand`, honoring `--window`; read back from the tree workspace node's
`collapsed` flag, which is `true` when collapsed and omitted when expanded).

**session**
- `new [--cwd DIR] [--workspace W] [--workspace-name NAME] [--create-workspace] [--command CMD] [--shell PATH] [--name NAME] [--no-select] [--wait] [--after SID | --before SID]` —
  create (and focus) a session. Target the workspace by id/prefix (`--workspace`) OR by name
  (`--workspace-name`, mutually exclusive); add `--create-workspace` to reuse-or-create the named
  workspace when absent. `--command` runs that program as the session process instead of an interactive
  shell — it runs UNDER a login shell (`<shell> -l -c '<cmd>'`), so your rc files run, `PATH` is yours (a
  bare Homebrew binary is found), and shell operators (`;`, `&&`, `|`, `$VAR`, redirects, globs) work as
  written. `--shell` picks the shell, as an absolute path, and defaults to the caller's `$SHELL`, so a
  session created from fish comes up fish; read it back on the `tree` node's `shell` (omitted on the app
  default) and it survives a relaunch. (`overlay open` is the exception and still has the exit-127 caveat —
  see below.)
  `--name` seeds the sidebar label (default: the auto basename). `--after`/`--before` place it directly
  after/before an anchor session (id/prefix/`active`) instead of appending — the anchor carries its own
  workspace, so it's mutually exclusive with `--workspace`/`--workspace-name`. `new --after active` =
  create right after the current session. `--no-select` creates in the background (selection/focus stay
  put; reads back as not `active`); `--wait` (needs `--command`) holds a command session open on the
  press-any-key prompt after it exits, persists, and reads back on the `tree` node's `commandWait`.
- `close [--target T ...]` — close one session, or repeat `--target` to close a batch with one
  grace-period undo.
- `select` · `rename <name>` · `duplicate` (fresh shell in the session's cwd — and its shell — right after it) · `reveal` (select the focused pane's cwd in Finder).
- `go --to next|prev|first|last|next-attention|prev-attention` — move the selection between sessions.
- `move <workspace>` (relocate) or `move --to up|down|top|bottom` (reorder within the workspace) or
  `move --after SID | --before SID` (place after/before an anchor session; the anchor carries its own
  workspace, so this relocates + positions in one shot, even cross-workspace). For workspace and
  after/before placement, repeat `--target` to move several sessions as one ordered block. Do not repeat
  `--target` with `--to up|down|top|bottom`.
- `type <text> [--stdin] [--select] [--pane left|right|scratch] [--target T ...] [--flagged]` — inject
  keystrokes (real typing, Enter included) into the main pane, the split pane with `--pane right`, or the
  scratch terminal (even hidden) with `--pane scratch`. Pass `--target "$ROOK_SESSION_ID"` to type into
  YOUR session, not the user's active one (see Addressing).
  BROADCAST the same text into a whole flock by repeating `--target`, or into every flagged session with
  `--flagged`; returns `result.affected` = how many sessions took the text. The two selectors are mutually
  exclusive, and `--select` works with a single target only.
- `copy` — print the session's selected text (does NOT touch the system clipboard).
- `paste` — paste the system clipboard into the session (the socket analogue of ⌘V; read it back with
  `session text`).
- `select-all` — select the session's entire terminal buffer (the socket analogue of ⌘A; read the
  selection back with `session copy`).
- `text [--all] [--lines N] [--pane left|right|scratch]` — print the session buffer as plain text. Default
  is the visible screen of the focused pane; `--pane scratch` reads the scratch terminal even while hidden;
  `--all` adds scrollback; `--lines N` keeps the last N lines.
- `search [needle] [--next|--prev|--close]` — search the terminal scrollback; prints the "N of M" counter.
- `split [on|off|toggle]` — side-by-side second shell (hide keeps it alive).
- `scratch [on|off|toggle] [--command CMD]` — full-coverage third shell (hide keeps it alive; `exit`
  recreates). `--command` (when showing) runs a program instead of a shell, run-once and under a login
  shell like `session new --command` (respawns the scratch if one is open). It takes no `--shell`: the
  scratch inherits the shell of the session it belongs to, as the split does. Target your own session with
  `--target "$ROOK_SESSION_ID"` (see Addressing).
- `filetree [on|off|toggle|refresh|reroot <path>]` — show/hide the session's file-tree panel (`refresh` re-roots it to the session's current cwd and re-reads it; `reroot <path>` re-roots it to an arbitrary directory instead).
- `markdown [open|close|toggle] [<path>]` — render a Markdown file in the session's preview panel (the
  right-hand column). `open` (the default) needs a path — relative resolves against the session's cwd,
  `~` expands; a missing file or a directory errors. `close` takes none; `toggle <path>` closes the panel
  when it already shows that file, else opens it (a bare `toggle` just closes an open one). Read the open
  file back from the tree node's `markdownPath`.
  Use it to put a plan or a report in front of the user without them leaving the terminal — the panel
  watches the file, so rewriting it re-renders live.
- `focus [left|right|other]` — move focus between split panes.
- `resize --split-ratio R | --grow-left D | --grow-right D` — move the split divider (no GUI/keymap
  equivalent — bind it via a `command "rookctl session resize …"` custom action). `--split-ratio` sets
  the absolute left-pane fraction (0..1, clamped to 0.05..0.95); `--grow-left`/`--grow-right` nudge it by
  a fraction. Prints the applied (clamped) fraction.
- `status <idle|active|completed|blocked> [--blink] [--auto-reset] [--sound NAME] [--color #rrggbb] [--shape NAME] [--pane left|right|scratch] [--pane-id TOKEN]` — set the sidebar agent glyph (`--sound default` or a system sound name plays a one-shot sound; `--color` tints the glyph for this call only, reverting on the next status set without it; `--shape circle|square|triangle|diamond|capsule|star` swaps the glyph for that plain silhouette for this call only, reverting the same way — a second discriminator for when the tint does not read (color blindness, a monochrome theme, a small glyph); omitting it keeps the state's own semantic glyph (ellipsis / exclamation mark / check mark); `--pane` records which pane set it — `left`=main, `right`=split, `scratch` — so foreground typing in another pane won't clear it and any user-initiated GUI selection (auto-follow, attention-nav ⌃⌥↑/↓, plain session nav, the command palettes, a sidebar row click) reveals the blocking pane, read back as the tree `statusPane` field; the socket `session go next-attention` only steps the selection, it does not itself reveal the pane; `--pane-id` takes the shell's stable `$ROOK_PANE_ID` token and OVERRIDES a stale `--pane` — the agent-status hook forwards it for you, so scripts normally leave it to the hook).
- `agent <claude|codex> [--id ID] [--from-hook] [--clear] [--config-dir DIR] [--pane left|right]` —
  remember which agent CONVERSATION the pane is on, so a restart can RESUME it instead of opening a blank
  agent (needs Settings ▸ General ▸ Resume agent conversations). Normally called by the agent's own
  `SessionStart` hook, which is the only party that knows the conversation id: `--from-hook` reads the
  hook's JSON payload from stdin and takes `session_id` out of it. `--config-dir` defaults to
  `$CLAUDE_CONFIG_DIR`/`$CODEX_HOME` and `--pane` to `$ROOK_PANE` (`scratch` is rejected). `--clear`
  forgets it. A report is accepted only from the pane's OWN agent (a nested `claude -p` you spawn cannot
  overwrite it). Reads back on the tree node as `agentSession`/`splitAgentSession`.
- `restore "<shell line>" | --none | --clear [--pane left|right] [--pane-id TOKEN]` — pin the command a
  session's PANE re-runs on the NEXT launch, verbatim shell and sticky until cleared. It wins over the
  pane's auto-captured foreground command; `--none` pins the pane to nothing (a plain shell), `--clear`
  drops the override and goes back to auto-capture. It never touches the RUNNING session and still obeys
  Settings ▸ General ▸ "Restore running commands on restart". Reads back on the tree node as
  `restoreCommand`/`splitRestoreCommand`. Distinct from the app-global `restore clear` below, which wipes
  every session's CAPTURED command instead.
- `flag [on|off|toggle|clear]` — flag a session for the flagged working-set view (`clear` unflags all).
- `seen [--target] [--window W]` — clear the session's unseen-notification badge WITHOUT changing the
  selection or focus (the focus-free counterpart to `notify`, which raises the badge). Idempotent — a
  no-op when already zero. Read the current count from the tree node's `unseen` field. Use it so an
  orchestrator can acknowledge a driven session's notifications without pulling focus to it.
- `background image <path> [--opacity F] [--fit contain|cover|stretch|none] [--position P] [--repeat]` ·
  `background text <text> [--color #rrggbb] [--opacity F] [--fit ...] [--position ...]` ·
  `background color <#rrggbb>` · `background clear` — composite an image (PNG/JPEG) or rasterized text
  behind the terminal as a watermark (auto-fitting the window, re-fits on resize), or set a solid
  terminal background color. Per session; survives restart. `--opacity` 0.0–1.0. (An image/text watermark
  renders the pane opaque, overriding window translucency, so it shows; a `color` takes no opacity and
  honors the Settings window translucency instead.)
- `overlay open <command> [--cwd DIR] [--wait] [--block] [--size-percent N] [--background-color #rrggbb] [--follow]` ·
  `overlay resize (--size-percent N | --full)` ·
  `overlay close` ·
  `overlay result` — run a program on top of a session; `--block` waits and exits with its status.
  `overlay resize` changes an ALREADY-OPEN overlay: `--size-percent N` (1-100) makes it a floating panel,
  `--full` switches it back to the full-pane overlay; the program keeps running (no re-spawn).
  Target with `--target "$ROOK_SESSION_ID"` for YOUR session (default `active` is the user's selection).
  **By default `overlay open` does NOT switch the user** — full and floating (`--size-percent`) both open
  on `--target` and run their program in the background; the panel appears when the user visits that
  session. **Pass `--follow` to select the target after opening** (a no-op if it is already active): use
  `--follow` when you want the user pulled to the overlay, omit it to open quietly on your own or another
  session.
  `--background-color` gives the overlay pane its own solid color, independent of the session's. An
  overlay is a real terminal (pty), which is also how you **display an image inline** — via the bundled
  `scripts/show-image.sh` (see below).
- `hud [open] <message> [--detail T] [--spinner] [--spinner-style S] [--position top|center|bottom] [--background-color #rrggbb] [--size-percent N]` ·
  `hud update <message> [--detail T] [--spinner] [--spinner-style S] [--position P] [--size-percent N]` ·
  `hud close` — post a small **passive** panel over the session saying what you are doing
  ("gathering options…"). Unlike an overlay it takes no input and steals nothing: the session keeps first
  responder, the user keeps typing, and the terminal behind it is neither dimmed nor click-blocked. Use it
  for the seconds an agent needs before it can show something (computing picker items, waiting on a slow
  command), then take it down. `open` is the default subcommand, so `hud "…"` posts; a message that is
  literally `update` or `close` needs the explicit `hud open` verb. `--detail` adds a dim second line,
  `--spinner` animates a glyph in the default `bar` style and `--spinner-style bar|braille|circle|blocks|dot`
  picks another, turning the spinner on by itself (`dot` blinks instead of animating, for a panel up for
  minutes; an update may switch style in place). `--spinner-style none` is accepted and leaves the panel
  static, so the `none` a read-back reports round-trips. `--position` places it vertically (default `center`; `top` and `bottom`
  hold a fixed margin off the pane edge automatically). The panel is sized from the message on both axes —
  width from the longest line, height from the number of them — so a title and a subtitle give a wide, short
  panel, not a square one. `--size-percent N` (1-100) overrides the WIDTH only, bounded to 10-80% of the
  pane, since a message must never cover the session it is about, so a requested 100 reads back as 80. The
  height always follows the message. `hud update` repaints in place with no re-spawn and no blink,
  and REPLACES the whole spec — repeat `--detail`/`--spinner`/`--position`/`--size-percent` to keep them,
  since an omitted one falls back to its DEFAULT rather than to what the panel is currently showing.
  It takes no `--background-color`: the surface reads that once at creation, so only a fresh `hud` changes
  it and `tree` keeps reporting the creation color across updates. Message and detail are capped at 256 characters and reject control characters, newline included.
  It occupies the SAME slot as `overlay open`, so: a second `hud` replaces the first, `overlay open`
  replaces a HUD (a running program is never replaced), `overlay close` and ⌘W take a HUD down,
  `overlay result` refuses with `no overlay result: the slot holds a hud`, `overlay resize --size-percent`
  works on it while `--full` is refused (`a hud is always floating: pass --size-percent, not --full`),
  and `surface zoom` will not address it. `hud update`/`hud close` with none up answer `no hud`. Read it
  back from the tree node's `hud` object; nothing announces it as an event, so poll `tree`.

**window** — `new [name] [--minimized] [--shell PATH]` · `list` · `select <id>` · `close <id>` · `rename <id> <name>` ·
`delete <id>` · `resize <id> --width W --height H` · `move <id> --x X --y Y [--display N]` ·
`zoom <id>` (maximize-to-screen toggle, the double-click-header gesture; a plain green-button click does full screen) ·
`fullscreen <id>` (toggle native macOS full screen, the green-button / ⌃⌘F action) ·
`minimize [id] [on|off|toggle]` (park a window in the Dock or bring it back — no mode means toggle; read
back from `window list`'s `minimized`. Minimizing a natively full-screen window is REJECTED with an error
rather than answered ok, because AppKit silently ignores it there).
`new --minimized` creates the window already parked, so a script can build a set of project windows
without each one flashing on screen and stealing focus. `new --shell PATH` spawns the window's first
session in that shell (absolute path; defaults to the caller's `$SHELL`), like `session new --shell`.

**surface** — `zoom [show|hide|toggle] [--target surface:<session-id>:left|right|scratch|overlay|quick] [--window W]`
— zoom a terminal surface to fill the window (sidebar hidden; a slim title-bar strip with an exit
button remains). Omit `--target` to use the active surface;
copy an explicit surface id from `tree --json` to address a hidden split/scratch or a background
session (`quick` is the id returned for a quick-terminal zoom). `hide` exits zoom; `toggle`
enters/exits only this zoom mode, not macOS window zoom.

**dashboard** — `dashboard <ids…> [--font-size N | --auto-size] [--window W]` opens a view-only grid
showing the named sessions' live panes; `dashboard --mru [--font-size N | --auto-size] [--window W]`
opens the window's most-recently-used sessions instead of naming ids; `dashboard --close [--window W]`
closes it. The cell unit is a session+pane: a non-split session is one cell, and a SPLIT session shows as
TWO cells (its left/primary pane and its right/split pane). View-only: no cell takes input — the keyboard
drives it (arrows move the highlight, Enter jumps into the highlighted session AND focuses that exact pane
then closes, Esc closes; an exit button in the stripped title bar does the same as Esc). `--font-size N`
sets an absolute cell font in points; `--auto-size` sizes cells relative to the Settings default font,
shrinking as the grid grows (the two are mutually exclusive; a non-positive size is rejected). The 9-cell
cap counts PANES (laid out `ceil(sqrt(n))`), so a set whose panes exceed 9 is capped to the first 9 panes
and the dropped-pane count is reported; ids are deduped and honor `--window` (default frontmost). `--mru`
is mutually exclusive with explicit ids and `--close`, and composes with the font flags. Read the state
back from the tree's top-level `dashboardMembers` (pane refs `<id>:left`/`<id>:right`, in grid order) /
`dashboardHighlighted` (a pane ref) / `dashboardFontSize`/`dashboardFontMode`. Zoom and the dashboard are
mutually exclusive: opening one CLOSES the other. Opening/closing resizes each pane's pty to its cell, so
programs may redraw — view-only means no input, not no process effect. The most-recently-used grid also has
a GUI opener: **⌘⇧D** (the `dashboard` built-in action), **Navigate ▸ Dashboard**, and the command palette's
**Dashboard** entry TOGGLE the frontmost window's MRU dashboard auto-sized (identical to `dashboard --mru
--auto-size`); no new control command, the socket `dashboard` command is unchanged.

**pick** — `pick [open] [--prompt P] [--query Q] [--allow-custom] [--follow] [--no-block] [--window W]` ·
`pick result <id>` · `pick cancel <id>` — ask the USER to choose from a list YOU supply, rendered in
Rook's own palette, and read the answer back.
This is the one family whose point is a question for the human: use it when the next step is a decision
that is not yours to make.
Choices come from stdin — one label per line (the label doubles as the id), or a JSON
`[{"id":…,"label":…,"subtitle":…}]` array when the first non-whitespace byte is `[`.
`open` BLOCKS until the user answers (they may take minutes), prints the answer as one JSON object, and
exits **0** picked/custom, **2** cancelled, 1 on failure — so a script branches on `$?` alone.
`--allow-custom` also accepts the typed query as the answer, which is what makes an EMPTY item list legal
(a plain free-text prompt); `--query` opens already filtered; `--follow` raises the window.
Matching is on the LABEL only (a subtitle is context, never a search key) and an empty query keeps YOUR
order, so rank the list yourself.
`--no-block` prints `{"id":"…"}` instead and leaves `pick result` (same JSON, exit 1 while still
`pending`) / `pick cancel` to you.
One picker per window — a second `open` there errors `pick already pending`; read the pending id from the
tree's top-level `pickPending`.
Esc, ⌘W, closing the window, and quitting Rook all answer `cancelled` rather than leaving you waiting.

**quick** — `[show|hide|toggle] [--shell PATH]` (visibility; read back from the tree's `quickVisible`.
`--shell` defaults to the caller's `$SHELL` and applies to the NEXT quick shell spawned — a live one is
not restarted) ·
`type TEXT` (or `--stdin`) inject keystrokes into the frontmost window's quick terminal ·
`text [--all] [--lines N]` read its screen back — the twins of `session type`/`session text`,
frontmost-window-only (no `--target`/`--window`/`--pane`).

**sidebar** — `[show|hide|toggle]` (visibility; read back from the tree's `sidebarVisible`) ·
`mode [tree|flagged|toggle]` (flip between the workspace tree and the flat flagged working-set list; read
back from the tree's top-level `sidebarMode`) · `expand [--window W]` (expand every workspace) ·
`collapse [--window W]` (collapse all workspaces except the active one, which stays expanded).
Visibility/mode act on the frontmost window; `expand`/`collapse` default to the frontmost but take a
`--window` selector to target any open window.

**notify** — `notify <body> [--title T]` — post a desktop notification attributed to a session. To signal that you need the user, prefer `session status` (`blocked`/`completed`), a persistent typed attention state rather than a one-shot banner; keep `notify` for a one-off nudge.

**font** — `font inc|dec|reset [--pane left|right|scratch]` — change a session pane's font size (omitted/`left` = main pane, `right` = the split pane, `scratch` = the scratch terminal). Read the resulting size back from `tree` (`fontSize`/`splitFontSize`/`scratchFontSize` per pane).

**keymap** — `keymap reload` — re-read `keymap.conf` (prints the parse-diagnostic count) ·
`keymap list` — the READ side: the config path, every built-in with the chord the keymap resolved for it
(`*` marks an overridden one, `-` a keyless one), the custom commands, the parse diagnostics, and the key
equivalents the MENU BAR is actually carrying. Compare the two halves — SwiftUI rebuilds the menu only on
the next app activation, so a chord can be right in the keymap and stale, hijacked, or on a `(disabled)`
item in the menu.

**config** - `config reload` - re-read the rook-scoped `ghostty.conf` (prints the diagnostic count).

**theme** — `theme list` (bundled themes, current marked `*`) · `theme set [name]` — set + persist the
terminal theme app-wide, per slot: a NAME sets the light/single theme (a dark theme, if set, is kept);
`theme set --dark <name>` sets the dark theme, which makes the terminal track the macOS Light/Dark
appearance automatically; `theme set --dark none` stops tracking. The app default is the bundled
**Rook** theme; omit the name for ghostty's built-in default ("default ghostty"); an unknown name errors.

**restore** — `restore clear` — clear every session's saved foreground command (the
restore-running-command capture) so the next restart restores plain shells.

## Displaying an image inline

This skill bundles `scripts/show-image.sh`. It opens an overlay (a real terminal) and renders the
image there via the kitty graphics protocol, which ghostty draws natively — no kitty binary and no
external image tool, just `base64` + `printf`. Run it with the image path (optional size percent,
default 60):

```bash
bash ~/.claude/skills/rook/scripts/show-image.sh <image> [size-percent]   # Claude Code
bash ~/.codex/skills/rook/scripts/show-image.sh <image> [size-percent]    # Codex
```

Do NOT print graphics escapes to your own tool stdout (the agent harness escapes the control bytes)
and do NOT run an image viewer in your tool shell (no controlling terminal). The overlay is what makes
it render. Outside Rook (`ROOK_ENABLED` unset) there is no overlay — fall back to `open <image>`.

## Troubleshooting and reporting

When the user hits a problem (a keymap editor that will not open, a custom action that does nothing,
notifications missing), diagnose it from inside the session first: inspect `rookctl tree --json`,
run `rookctl keymap reload` for the parse-diagnostic count, `rookctl keymap list` to see what each
chord actually resolved to (and what the menu bar carries), and read the unified logs under
subsystem `com.rook.app`. If it turns out to be a bug, offer to help file it.

**Filing is opt-in and draft-first.** Never run a `gh` command without the user's explicit approval.
Decide first whether it is a bug (a supported feature misbehaving → a GitHub **issue**) or something
not supported / a question / an idea (→ a GitHub **Discussion**, category `Ideas` or `Q&A`). Draft the
title and body, show it to the user, scrub anything private (tokens, hostnames, usernames in paths,
selection/clipboard text), and only post after an explicit go-ahead. If `gh` is missing or not
authenticated, hand the user the prefilled text plus the new-issue / new-discussion URL instead.

Full detail, templates, and the exact `gh` commands are in **troubleshooting.md**.

## Reference files

- **reference.md** — full per-command detail: every flag, the JSON return shapes
  (`result.id`/`text`/`exitCode`/`count`/`affected`/`tree`/`windows`/`events`), error strings, the
  cursor contract for `events.read`, the scratch/overlay/split
  lifecycle, and the keymap.conf format (`map` / `command`, chords, leaders, `{AGT_X}` tokens).
- **examples.md** — copy-paste rookctl recipes for common tasks (build a layout, run a program in a
  blocking overlay and read its status, type into a fresh session, ask the user to choose and branch on
  the answer, notify, inspect the tree, watch the event stream and keep a durable cursor).
- **troubleshooting.md** — diagnosing common problems (keymap editor, custom actions, missed events and
  the three cursor errors, logs) and the
  bug-issue / feature-Discussion reporting workflow (draft-first, scrub, never post without approval).
- **scripts/show-image.sh** — bundled helper that displays an image inline in an overlay (see above).

Read those files when you need exact flags, return shapes, or worked examples.
