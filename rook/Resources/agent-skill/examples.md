# Rook control recipes

Worked `rookctl` examples. See `reference.md` for exact flags and return shapes. All assume
`rookctl` is on PATH and you are inside a Rook session (`ROOK_ENABLED=1`).

## Inspect the current state

```bash
rookctl tree --json        # workspaces -> sessions, active/split/overlay/scratch/flagged flags, surface ids
rookctl window list --json # windows, with open/active flags

# what is each pane RUNNING right now (foreground argv; absent when at the shell prompt)
rookctl tree --json | jq -r '.result.tree.workspaces[].sessions[] | "\(.name): \(.foreground // "shell")"'
```

## Watch what happens instead of diffing the tree

`rookctl events` follows the app's event ring, so you no longer poll `tree --json` and diff snapshots.
Polling cannot see a transition that flipped and flipped back between two reads — an agent that blocked
and unblocked simply never happened. `--json` prints one bare event object per line (NDJSON).

```bash
rookctl events                                   # human column lines: HH:mm:ss kind name …
rookctl events --kind status,session.closed      # only these kinds (repeatable and/or comma-separated)

# react to any session blocking, wherever it happens (jq --unbuffered, or you buffer a whole page)
rookctl events --json --kind status \
  | jq -r --unbuffered 'select(.payload.status == "blocked") | .session' \
  | while read -r id; do rookctl session flag on --target "$id"; done
```

It is a poll loop over the one-shot `events.read`, not a push socket: it sleeps 0.25 s only after an
EMPTY page, so a burst drains at full speed. It exits non-zero on any failure — a dead socket, or one of
the three cursor errors below — and never keeps printing as if nothing broke.

### Keep the cursor, and never restart silently

Starting with NO cursor means "subscribe from now": there is no history replay. So a supervisor that just
restarts `rookctl events` skips everything that happened while it was down. That is fine — as long as you
RECORD the gap instead of pretending it was quiet:

```bash
while :; do
  rookctl events --json >> ~/rook-events.ndjson
  echo "watcher stopped at $(date -Iseconds); events until it comes back are LOST" >&2
  sleep 1
done
```

`rookctl events` keeps its cursor in memory only, so it cannot resume across its own restart. For a
durable cursor, drive `events.read` yourself — one JSON request per connection, one reply, then the app
closes the socket (`--run`/`--after` are a PAIR; `after` rides as a string):

```bash
read_events() {  # $1 = run (empty on the first call), $2 = after
  if [ -n "$1" ]; then a="{\"run\":\"$1\",\"after\":\"$2\",\"limit\":200}"; else a='{"limit":200}'; fi
  printf '{"cmd":"events.read","args":%s}\n' "$a" | nc -U "$ROOK_SOCKET"
}

reply=$(read_events "$run" "$after")
if [ "$(jq -r .ok <<<"$reply")" != "true" ]; then
  case "$(jq -r .error <<<"$reply")" in
    "event run changed")
      echo "rook restarted — the old run's events are gone for good" >&2 ;;
    "event cursor expired")
      echo "fell more than 4096 events behind — the middle is gone" >&2 ;;
    "event cursor is ahead of the current sequence")
      echo "cursor belongs to a different ring (stale state file?)" >&2 ;;
  esac
  # ALL THREE still carry the current anchor in the SAME reply, so rebaseline from it — deliberately,
  # after recording the gap. Never swallow the error and start over: the server refuses to re-anchor
  # you silently precisely so a missed stretch cannot read as "nothing happened".
fi
run=$(jq -r '.result.events.run' <<<"$reply")    # present on ok:true AND on all three failures
after=$(jq -r '.result.events.next' <<<"$reply") # feed back as --after; advances even on an empty page
jq -c '.result.events.items[]' <<<"$reply" >> ~/rook-events.ndjson
```

Persist `run`+`after` after each page and you resume exactly where you stopped — as long as rook has not
restarted (a new run) and you have not fallen 4096 events behind (an expired cursor).

## Reset the restore-on-restart commands

The opt-in "Restore running commands on restart" setting saves each pane's foreground command at quit.
Clear those saved commands so the next launch restores plain shells:

```bash
rookctl restore clear
```

## Create a session and type into it

`session new` returns the new id and focuses the session. Capture the id, then type. The session is
realized eagerly, so no `--select` is needed.

```bash
sid=$(rookctl session new --cwd "$HOME/project" --json | jq -r '.result.id')
rookctl session type "git status" --target "$sid"
rookctl session type $'\n' --target "$sid"     # send Return (or include it in the text)
rookctl session split on --target "$sid"                    # open a split first
rookctl session type $'ls\n' --target "$sid" --pane right   # then type into the split pane
```

Typing goes to the session's main (left) pane by default; `--pane right` targets the split pane and
errors with `session has no split pane` when there is none. In a custom keymap command, `$AGT_PANE`
holds the pane the shortcut fired from, so `session type --pane "$AGT_PANE"` types back into it.

## Broadcast one line into a flock of agents

Repeat `--target` to type the same text into several sessions in one call, or use `--flagged` to hit every
flagged session of the window — no shell loop, and one unknown id fails the whole thing before anything is
typed:

```bash
rookctl session type $'/compact\n' --target "$a" --target "$b" --target "$c"
rookctl session flag on --target "$a"                        # mark the flock once…
rookctl session type $'git pull --rebase\n' --flagged         # …then broadcast to it
rookctl session type $'/clear\n' --flagged --json | jq '.result.affected'   # how many took it
```

The two selectors are mutually exclusive, and `--select` only works with a single target. Injection is
best-effort with an honest count: `result.affected` is how many sessions actually took the text, and a
partial failure answers `ok: false` while still carrying that count — so read `affected` instead of
assuming all-or-nothing. `--flagged` with nothing flagged is a successful `affected: 0`.

Run a command AS the session's process (closes when it exits, no echoed command line):

```bash
rookctl session new --command "ssh host -p 22"     # a default-PATH binary: argv-split (quotes respected), no shell, no echo
rookctl session new --command "zsh -lc 'htop'"     # Homebrew/non-default binary: --command has the app's GUI PATH, so wrap in a login shell (or use an absolute path); bare "htop" exits 127
rookctl session new --command "zsh -lc 'make test'" --wait  # hold the session on the press-any-key prompt after the command exits (--wait needs --command)
rookctl session new --cwd "$HOME/project" --no-select       # background create: appended, but the current session stays selected/focused
rookctl session duplicate                                   # duplicate the current session into a fresh shell in its cwd, right after it (directory only)
```

Create a session pre-named (label set at creation, no follow-up rename):

```bash
rookctl session new --name "myhost" --command "ssh user@host"
```

Open a session in a named workspace, creating the workspace once and reusing it after (idempotent — no
duplicate "servers" workspace on repeated calls):

```bash
rookctl session new --workspace-name servers --create-workspace --name "myhost" --command "ssh user@host"
```

## Build a small layout

```bash
ws=$(rookctl workspace new "build" --json | jq -r '.result.id')
a=$(rookctl session new --workspace "$ws" --cwd "$HOME/proj" --json | jq -r '.result.id')
rookctl session rename "server" --target "$a"
rookctl session split on --target "$a"          # second shell side by side
rookctl session resize --split-ratio 0.7 --target "$a"   # left pane gets 70% (prints 0.700)
b=$(rookctl session new --workspace "$ws" --json | jq -r '.result.id')
rookctl session rename "logs" --target "$b"
```

## Build a workspace without it popping open

Creating a workspace normally opens its row in the sidebar and the first session steals the selection.
`workspace new --collapsed` plus `session new --no-select` builds the whole thing quietly, leaving the
user exactly where they were.

```bash
ws=$(rookctl workspace new "nightly" --collapsed --json | jq -r '.result.id')
for d in api web worker; do
  rookctl session new --workspace "$ws" --cwd "$HOME/proj/$d" --name "$d" --no-select
done

# read the state back (true = collapsed; the field is omitted once it is expanded)
rookctl tree --json | jq -r --arg ws "$ws" \
  '.result.tree.workspaces[] | select(.id == $ws) | .collapsed'

rookctl workspace expand --target "$ws"     # open it when the user should see it
rookctl workspace collapse --target "$ws"   # ...and fold it away again
```

`workspace collapse`/`expand` address ONE workspace and honor `--window`; the window-wide
`sidebar collapse`/`sidebar expand` are the all-workspace version.

## Place a session next to another instead of appending

`session new` appends at the end of the workspace by default. `--after`/`--before` place it directly
after/before an anchor session in one round-trip — no `move --to up` walk. The anchor is a session
address (id / unique prefix / `active`) and carries its own workspace, so it names the destination
itself (mutually exclusive with `--workspace`/`--workspace-name`).

```bash
# the headline case: create right after the current session
rookctl session new --after active

# create right before a specific session (by unique prefix)
rookctl session new --before 3f2a --name "notes"
```

`session move` gains the same placement mode. Relocate a session and slot it after/before an anchor —
wherever the anchor lives, even in another workspace — in one shot, with no visible row-by-row shuffle:

```bash
# move the current session to sit right after another (cross-workspace if the anchor is elsewhere)
rookctl session move --after 3f2a --target active
rookctl session move --before "$logs" --target "$server"

# move several sessions together as one ordered block
rookctl session move "$ws" --target "$server" --target "$logs"
rookctl session move --after "$anchor" --target "$server" --target "$logs"

# close several sessions with one grace-period undo
rookctl session close --target "$server" --target "$logs"
```

`--after`/`--before` are mutually exclusive with each other, with `--to`, and with a destination
workspace — the anchor already picks the workspace. Repeated `--target` is only for workspace and
after/before placement, not `--to up|down|top|bottom`.

## Resize the split divider from a keybinding

The divider is otherwise mouse-drag only — there is no built-in resize action, so bind keys to the CLI
with `command "<name>" <chord> <shell…>` custom actions in `keymap.conf` (then `rookctl keymap reload`):

```conf
# grow/shrink the left pane by 5% per press; cmd+ctrl+0 resets to an even split
command "grow left pane"  cmd+ctrl+l rookctl session resize --grow-left 0.05
command "grow right pane" cmd+ctrl+h rookctl session resize --grow-right 0.05
command "even split"      cmd+ctrl+0 rookctl session resize --split-ratio 0.5
```

`--split-ratio` is absolute (0..1); `--grow-left`/`--grow-right` are relative nudges. All clamp to
0.05..0.95 and print the applied fraction.

## Run a program in a blocking overlay and read its status

`--block` waits for the program to exit and makes rookctl exit with the program's status. The
program renders normally in the overlay; read its OUTPUT from the program's own output file.

Pass `--target "$ROOK_SESSION_ID"` so the overlay attaches to YOUR (the calling) session. Without
`--target` it opens on whatever session is currently active — so if the user has moved to another
session or workspace, an agent (e.g. running revdiff) pops a blocking full-pane overlay on the WRONG
session. Always target your own session for these recipes.

```bash
rookctl session overlay open "revdiff HEAD~3 --output /tmp/notes.md" --target "$ROOK_SESSION_ID" --block   # this session
echo "exit status: $?"
cat /tmp/notes.md
```

Floating panel variant (session stays visible behind it). Like a full overlay it opens in the background
without switching the user; add `--follow` when you want the user pulled to the overlay:

```bash
rookctl session overlay open "zsh -lc 'htop'" --target "$ROOK_SESSION_ID" --size-percent 70   # login shell so Homebrew's htop is on PATH; bare "htop" flashes open then vanishes (exit 127)
# tint the overlay pane so it stands out from the session behind it:
rookctl session overlay open "revdiff HEAD~3" --target "$ROOK_SESSION_ID" --size-percent 80 --background-color "#2a1a3a"
# switch the user to the target as it opens:
rookctl session overlay open "revdiff HEAD~3" --target "$ROOK_SESSION_ID" --size-percent 80 --follow
# resize the open overlay in place (the program keeps running): shrink to a floating panel, then back to full
rookctl session overlay resize --size-percent 60 --target "$ROOK_SESSION_ID"
rookctl session overlay resize --full --target "$ROOK_SESSION_ID"
# ... later
rookctl session overlay close
```

Manual open + poll for status instead of `--block`:

```bash
rookctl session overlay open "make test" --target "$ROOK_SESSION_ID"   # this session
rookctl session overlay result --json   # errors "still running" until it exits, then result.exitCode
```

## Show an image inline

To show the user an image (a generated favicon, a chart, a preview), run the bundled
`scripts/show-image.sh` with the image path. It opens an overlay (a real terminal) and renders the
image there via the kitty graphics protocol, which ghostty draws natively — no kitty binary and no
external image tool, just `base64` + `printf`. An optional second argument sets the panel size percent
(default 60):

```bash
bash ~/.claude/skills/rook/scripts/show-image.sh /abs/path/to/img.png 60   # Claude Code
bash ~/.codex/skills/rook/scripts/show-image.sh /abs/path/to/img.png 60    # Codex
```

The image shows in a floating overlay over the active session; dismiss it with Enter in the panel or
`rookctl session overlay close`. Do NOT emit graphics escapes to your own tool stdout (the harness
escapes the control bytes) and do NOT run an image viewer in your tool shell (no controlling
terminal) — the overlay's real terminal is what renders.

Tiny images (a favicon) enlarge with nearest-neighbor first, so the pixels stay crisp:

```bash
magick favicon.png -filter point -resize 256x256 /tmp/big.png
```

Outside Rook (`ROOK_ENABLED` unset) there is no overlay — fall back to `open img.png` (Preview).

## Set a background watermark or color

A persistent backdrop behind the terminal grid (distinct from `show-image.sh`, which is a transient
overlay). An image or rasterized-text watermark (auto-fitting the window, re-fitting on resize), or a
solid terminal background color — per session, surviving a relaunch.

```bash
# rasterized text watermark on this session, faint
rookctl session background text "STAGING" --color '#ff5500' --opacity 0.15 --target "$ROOK_SESSION_ID"

# an image (PNG/JPEG), scaled to cover the window
rookctl session background image /abs/logo.png --fit cover --opacity 0.2 --target "$ROOK_SESSION_ID"

# a solid background color — e.g. mark a PROD session so it can't be mistaken for a scratch one
rookctl session background color '#3a0d0d' --target "$ROOK_SESSION_ID"

# remove it
rookctl session background clear --target "$ROOK_SESSION_ID"
```

`--opacity` is 0.0–1.0; `--fit` is `contain` (default) / `cover` / `stretch` / `none`; `--position` is
`center` (default) or an edge/corner anchor. An image/text watermark renders the pane opaque (overriding
window translucency), so it is always visible; a `color` takes no opacity and honors the Settings window
translucency (solid when off, blurred/translucent when on).

## Toggle the scratch terminal

A third per-session full-coverage shell. Hide keeps it alive; `exit` in it recreates on next show.

```bash
rookctl session scratch on        # show (selects the target)
rookctl session scratch off       # hide, shell stays alive
rookctl session scratch toggle
rookctl session scratch on --command "zsh -lc 'lazygit'"   # run a program instead of a shell (run-once); login-shell wrap so Homebrew's PATH is found (bare "lazygit" exits 127)
```

## Toggle, refresh, or re-root the file-tree panel

Show, hide, refresh, or re-root the session's file-tree panel. `refresh` re-roots the file tree to the
session's current cwd and re-reads it; `reroot <path>` re-roots it to an arbitrary directory instead
(a missing/non-directory path errors). Neither changes visibility. Read the current root back from the
tree node's `fileTreeRoot`.

```bash
rookctl session filetree on              # show the file-tree panel (roots at the session cwd)
rookctl session filetree refresh         # re-root the tree to the session's current cwd (and re-read)
rookctl session filetree reroot /some/dir # re-root the tree to an arbitrary directory
rookctl session filetree toggle          # on|off|toggle|refresh|reroot <path>
```

## Show a plan (or any Markdown) in the preview panel

Put a rendered document in front of the user without them leaving the terminal: the panel opens to the
right of the session and re-renders itself whenever you rewrite the file, so a plan you keep updating
stays current on screen. Target YOUR session, not `active`.

```bash
rookctl session markdown open ./PLAN.md --target "$ROOK_SESSION_ID"   # relative resolves against the session cwd
rookctl session markdown open ~/notes/review.md --target "$ROOK_SESSION_ID"
rookctl tree --json | jq -r '..|.markdownPath? // empty'              # which file is on screen
rookctl session markdown close --target "$ROOK_SESSION_ID"
```

A missing file (or a directory) errors with `no such file: <path>`. The user can also just ⌘-click a
Markdown path you print in the terminal — same panel.

## Drive the quick terminal

The quick terminal is the window's throwaway overlay (not in the session tree). Show it, type into it,
and read it back — the twins of `session type`/`session text`, but always the frontmost window's quick
terminal (no `--target`/`--pane`).

```bash
rookctl quick show                                 # drop the overlay over whatever is active
rookctl quick type 'ls -la'$'\n'                   # inject keystrokes (\n runs it)
echo "some payload" | rookctl quick type --stdin   # pipe stdin in (e.g. a paste helper)
rookctl quick text --all                           # read its screen + scrollback back
rookctl tree --json | jq .result.tree.quickVisible # is it open right now?
```

## Flag a working set and view just the flagged sessions

Flag a few sessions across workspaces, then flip the sidebar to the flat flagged list (each row labeled
`session : workspace`). The flag is durable (persisted per session); `sidebar mode` is per-window.

```bash
rookctl session flag on --target "$ROOK_SESSION_ID"   # flag this session
rookctl session flag on --target a1b2                   # flag another (any workspace)
rookctl sidebar mode flagged                            # show only the flagged sessions
rookctl session go --to next                            # in flagged mode, nav steps the flagged set only
rookctl sidebar mode tree                               # back to the full tree
rookctl session flag clear                              # unflag everything in the window
```

## Acknowledge a driven session's notifications without stealing focus

An orchestrator relaying a session's output elsewhere (Telegram, another agent) fires `notify` to signal
"your turn", which raises the session's red unseen badge. Nothing normally clears that badge except
visiting the session — which pulls the selection to it. `session seen` clears it in place, so the badge
stays a real attention signal on the sessions a human tends while the driven ones stay clean.

```bash
rookctl notify "your turn" --target "$SID"             # raises the unseen badge (body is positional)
rookctl tree --json | jq '.result.tree.workspaces[].sessions[] | {id, unseen}'  # read the counts
rookctl session seen --target "$SID"                   # clear it, selection/focus unchanged
```

## Build a working set of workspaces, then apply it

The sidebar's focus filter narrows the tree to a SET of workspaces, and that is TWO separate pieces of
state: WHICH workspaces are marked (`marked` on each workspace node) and WHETHER the set filters the tree
(`workspaceFilter` at the tree's top level).
A node's `focused` is exactly their conjunction — `focused == marked && workspaceFilter`.

`workspace focus add` marks a workspace and NEVER touches the filter flag, which is what makes a set
buildable: mark the members one at a time with the whole tree still on screen, then apply the lot with
ONE `workspace filter on`.

```bash
rookctl workspace focus add --target "$ROOK_WORKSPACE_ID"   # mark; the tree does not change
rookctl workspace focus add --target a1b2                   # mark another
rookctl workspace focus add --target 7f3c                   # …and another
rookctl workspace filter on                                 # NOW the tree narrows to the three
```

Marking three workspaces and seeing nothing happen is the designed behavior, not a bug — the `filter on`
is the step that applies it.
Reach for `workspace focus on` per workspace instead and you end up with the LAST one alone, because `on`
REPLACES the set:

```bash
rookctl workspace focus on --target "$ROOK_WORKSPACE_ID"    # zoom to this one alone (replace + apply)
rookctl workspace focus off --target a1b2                   # REMOVE a member (`off` is the remove mode;
                                                            #   there is no `remove` token)
rookctl workspace focus toggle --target a1b2                # replace-toggle: clears everything when a1b2
                                                            #   is the sole member of an APPLIED filter
```

Removing the last member switches the filter off with it. There is no membership-toggle mode and no bulk
clear over the socket (the GUI's Clear Focus has no control twin): read `marked` and send `add` or `off`
yourself, looping `off` over the members when you want the set emptied.

## Peek at the whole tree, then come back to the set

`workspace filter` flips only the FLAG, so the set survives — that is how you look at everything and come
straight back, without re-naming a single workspace.

```bash
rookctl workspace filter off                               # whole tree, set kept
# …look around: select sessions in the other workspaces…
rookctl workspace filter on                                # back to the marked set
rookctl workspace filter toggle                            # or flip it (the default mode)
```

It matters beyond convenience: an INVOLUNTARY jump out of the marked set — idle auto-follow to a blocked
session, attention nav (⌃⌥↑/⌃⌥↓), a click on a notification banner, the dashboard, the recent-sessions
popover — switches the filter off by itself and KEEPS the set.
One `workspace filter on` brings the working set back; an explicit `workspace focus off` instead unmarks
that workspace, and once every member is gone there is nothing left to come back to.

```bash
# what state am I in? focused == marked && workspaceFilter
rookctl tree --json | jq -r '.result.tree
  | (.workspaceFilter | tostring) as $f
  | .workspaces[] | select(.marked) | "\(.name): marked, filtering=\($f)"'

# which workspace ROWS are on screen right now?
#   visible  ⟺  sidebarVisible && sidebarMode == "tree" && (!workspaceFilter || marked)
rookctl tree --json | jq -r '.result.tree
  | (.workspaceFilter == true) as $f
  | if (.sidebarVisible == true and .sidebarMode == "tree")
    then .workspaces[] | select($f == false or .marked == true) | .name
    else empty end'

# re-apply only when something is marked but not filtering (idempotent either way)
rookctl tree --json \
  | jq -e '.result.tree | (.workspaceFilter | not) and ([.workspaces[] | select(.marked)] | length > 0)' \
  >/dev/null && rookctl workspace filter on
```

Do not shorten that visibility predicate. `focused` alone reports nothing visible whenever the filter is
off — exactly when the WHOLE tree is on screen — and a bare `!workspaceFilter || marked` claims rows are
visible in `flagged` mode and behind a hidden sidebar, where no workspace row renders at all.

`filter on` with an EMPTY set is a plain no-op — the command still answers `ok`, so read `workspaceFilter`
back rather than trusting the exit status. It is window-scoped (no `--target`); add `--window W` to drive
another window.

## Borrow the user's workspace filter and give it back

Record the set AND the flag, do the work that needs the whole tree, then replay it.
Restore with N × `focus add` plus ONE `filter on|off`; `workspace focus on` is the WRONG tool for a
restore, since it replaces the set with the single workspace you name and a three-workspace set comes
back as a one-workspace zoom.

```bash
SNAP=$(rookctl tree --json)
MARKED=$(jq -r '.result.tree.workspaces[] | select(.marked) | .id' <<<"$SNAP")
FILTER=$(jq -r '.result.tree.workspaceFilter' <<<"$SNAP")

rookctl workspace filter off                                  # full tree while you work
# …do the work…

for id in $MARKED; do rookctl workspace focus add --target "$id"; done
if [ "$FILTER" = true ]; then rookctl workspace filter on; else rookctl workspace filter off; fi
```

Two things to know before restoring.
A workspace DELETED while you worked drops out of the set on its own, and re-adding its id fails with a
`notFound` error rather than marking a phantom — so that member is simply lost, and the loop above keeps
going.
And the adds are ADDITIVE: if the user marked something new meanwhile you get the union, so loop
`workspace focus off` over the CURRENT members first when you need the recorded set exactly.

## Give the workspaces their own icons and colors

Both are persisted, so they survive a relaunch, and both read back on the tree workspace node — which
makes record-then-restore safe.

```bash
# color tints the ICON (not the row text)
rookctl workspace color "#ff8800" --target "$ROOK_WORKSPACE_ID"  # this workspace: orange
rookctl workspace color clear --target a1b2                        # back to the theme default

# an icon is an SF Symbol name, a single emoji, or an image file
rookctl workspace icon hammer.fill --target "$ROOK_WORKSPACE_ID"  # tinted by the color above
rookctl workspace icon "🚀" --target a1b2                           # emoji keeps its own colors
rookctl workspace icon ~/icons/rocket.svg --target a1b2             # copied into the state dir
rookctl workspace icon clear --target a1b2                          # back to the default glyph

# record the current appearance, change it, restore it
old=$(rookctl tree --json | jq -r '.result.tree.workspaces[] | select(.id | startswith("a1b2")) | .icon // "clear"')
rookctl workspace icon leaf.fill --target a1b2
rookctl workspace icon "$old" --target a1b2
```

The color applies only to a symbol or a MONOCHROME image (one color over transparency — those render as
templates the color can repaint). A colored image of any format and an emoji carry their own colors, so the
color is ignored for them.

## Give a workspace a root directory (new sessions open there)

Set a workspace's root so every new session in it opens in your project directory instead of the global
default. It is a HARD override of the new-session-directory setting; an explicit `session new --cwd` still
wins. Persisted and read back on the tree workspace node's `root`, so record-then-restore is safe.

```bash
rookctl workspace root ~/src/rook --target "$ROOK_WORKSPACE_ID"  # new sessions here open in ~/src/rook
rookctl session new                                              # → opens in ~/src/rook
rookctl workspace root clear --target "$ROOK_WORKSPACE_ID"       # back to the global setting

# record the current root, change it, restore it
old=$(rookctl tree --json | jq -r '.result.tree.workspaces[] | select(.id | startswith("a1b2")) | .root // "clear"')
rookctl workspace root /tmp/scratch --target a1b2
rookctl workspace root "$old" --target a1b2
```

## Expand or collapse the sidebar tree

Open every workspace at once, or collapse all but the active one (the workspace of the active session,
which stays expanded and scrolled into view) to cut clutter. Defaults to the frontmost window; pass
`--window` to target any open window. A no-op in flagged mode.

```bash
rookctl sidebar expand                                 # expand every workspace (frontmost window)
rookctl sidebar collapse                               # collapse all but the active workspace
rookctl sidebar collapse --window "$ROOK_WINDOW_ID"  # collapse a specific window's sidebar
```

## Copy a selection and reuse it

`session copy` returns the selection as text (it does not use the system clipboard). Pipe it onward.

```bash
sel=$(rookctl session copy --json | jq -r '.result.text')
rookctl session type "$sel" --target "$other"
```

`session select-all` selects the whole buffer, then `session copy` reads it back (or use `session text --all`):

```bash
rookctl session select-all --target "$other"
buf=$(rookctl session copy --target "$other" --json | jq -r '.result.text')
```

`session paste` pastes the system clipboard into a session — the socket analogue of ⌘V:

```bash
printf 'deploy staging' | pbcopy
rookctl session paste --target "$other"   # lands at the prompt, not submitted
```

## Read a session's buffer as text

`session text` returns the terminal buffer as plain text in `result.text` — the visible screen by
default, the whole scrollback with `--all`, or the last N lines with `--lines N`. Pipe it into
`grep`/`fzf` to extract URLs, paths, etc.

```bash
rookctl session text                         # the visible screen of the focused pane
rookctl session text --lines 50              # the last 50 lines of the buffer
rookctl session text --pane right            # the split pane (errors if there is no split)
rookctl session text --pane scratch --all    # the scratch terminal's full buffer, even while it's hidden
# extract every URL from the full scrollback:
rookctl session text --all --json | jq -r '.result.text' | grep -oE 'https?://[^ ]+'
```

`--pane scratch` reads (and `session type --pane scratch` writes) the session's scratch terminal whether
or not it is on screen, since its shell is kept alive when hidden. Handy for "I ran a deploy in the
scratch, read its output and tell me what broke" without leaving the scratch open:

```bash
rookctl session scratch on                             # open the scratch once so it exists
rookctl session type $'./deploy.sh\n' --pane scratch   # run it in the scratch (even after you hide it)
rookctl session text --pane scratch --all              # read the result back
```

## Search the terminal scrollback

`session search` opens a search bar over the focused terminal and highlights matches in the live
output. It returns the "N of M" counter; step matches with `--next`/`--prev`, close with `--close`.

```bash
rookctl session search "error"          # highlight matches, print the counter (e.g. "1 of 7")
rookctl session search --next           # step to the next match
rookctl session search --prev           # step back
n=$(rookctl session search "warn" --json | jq -r '.result.count')   # how many matches
rookctl session search --close          # close the search bar
```

## Notify the user in a specific session

```bash
rookctl notify "build finished" --title "CI"                 # active session
rookctl notify "tests failed" --target "$sid"               # a specific session
```

## Agent status glyph

```bash
rookctl session status active --blink --target "$ROOK_SESSION_ID"   # working
rookctl session status completed --auto-reset --target "$ROOK_SESSION_ID"  # one-shot done flash
rookctl session status blocked --sound default --target "$ROOK_SESSION_ID" # needs input, with a beep
rookctl session status completed --sound Glass --target "$ROOK_SESSION_ID" # done, with a named sound
rookctl session status blocked --color '#ff0000' --target "$ROOK_SESSION_ID" # per-call red tint (reverts on next status)
rookctl session status blocked --pane right --target "$ROOK_SESSION_ID"     # a split-pane agent tags its pane (see below)
rookctl session status idle --target "$ROOK_SESSION_ID"             # clear
```

## Tell your states apart by SHAPE, not only by color

The three states already have distinct glyphs (ellipsis / exclamation mark / check mark) in distinct
colors. Add `--shape` when you need a second discriminator the tint cannot give you — a color-blind user, a
monochrome theme, a sidebar full of small glyphs, or several agents you want to tell apart at a glance
while they sit in the same state.

```bash
# one agent's own visual signature, repeated on every call (the shape is per call, see below)
rookctl session status active --blink --shape triangle --target "$ROOK_SESSION_ID"
rookctl session status blocked --shape triangle --color '#ff0000' --target "$ROOK_SESSION_ID"
rookctl session status completed --auto-reset --shape triangle --target "$ROOK_SESSION_ID"

# or a shape per state, so the outline alone says which is which
rookctl session status active   --shape capsule  --target "$ROOK_SESSION_ID"
rookctl session status blocked  --shape triangle --target "$ROOK_SESSION_ID"
rookctl session status completed --shape circle  --target "$ROOK_SESSION_ID"

# read it back (omitted when idle or drawing the default glyph)
rookctl tree --json | jq -r '.result.tree.workspaces[].sessions[]
  | select(.status) | "\(.name): \(.status) \(.statusShape // "default") \(.statusColor // "")"'
```

Shapes: `circle`, `square`, `triangle`, `diamond`, `capsule`, `star`. It is PER CALL, exactly like
`--color` — the next `session status` without `--shape` reverts to the state's own semantic glyph, so pass
it on every call you want shaped. Omitting it changes nothing at all. An unknown name is rejected before
the status is touched, so a typo leaves the previous status standing rather than half-applying.

## Tag the blocking pane so navigation lands on it

An agent running in a split or scratch pane sets `--pane` so its block survives foreground typing in
another pane and the user's attention navigation lands on the RIGHT pane — the split, or a hidden scratch,
not the main pane. Auto-follow and any GUI selection — the attention-nav (⌃⌥↑/⌃⌥↓), plain session nav,
the command palettes, and a sidebar row click — reveal and focus the tagged pane; the socket
`session go --to next-attention` only steps the selection, it does not move focus into the pane.
Without `--pane` the status is treated as coming from the main (`left`) pane, so a block set from the split
can be wiped by typing in the main pane and the reveal lands on the wrong surface.

```bash
# an agent working in the split pane; $AGT_PANE is set in a custom keymap command, else name it
rookctl session status active --pane right --target "$ROOK_SESSION_ID"   # working, in the split
rookctl session status blocked --pane right --target "$ROOK_SESSION_ID"  # needs input; the user's attention nav focuses the split

# an agent working in the scratch terminal (even while it is hidden)
rookctl session status blocked --pane scratch --target "$ROOK_SESSION_ID" # the user's attention nav SHOWS + focuses the scratch

# read back which pane blocked
rookctl tree --json | jq -r '.result.tree.workspaces[].sessions[] | select(.status) | "\(.name): \(.status) in \(.statusPane // "left")"'
```

`--pane left` (or omitting it) is the main pane. Feed a keymap command's `$AGT_PANE` straight through
(`session status blocked --pane "$AGT_PANE"`) to tag the exact pane a shortcut fired from.

## Inspect or reset the conversation a pane would resume

With Settings ▸ General ▸ Resume agent conversations on, a restored agent pane comes back on the
conversation its `SessionStart` hook reported (`session agent`), not a blank one. Read what is remembered,
and clear it when a pane should come back fresh:

```bash
# which conversation would each pane resume?
rookctl tree --json | jq -r '.result.tree.workspaces[].sessions[]
  | select(.agentSession) | "\(.name): \(.agentSession.kind) \(.agentSession.id) [\(.agentSession.configDir // "default profile")]"'

# the split pane's conversation is a separate field
rookctl tree --json | jq -r '.result.tree.workspaces[].sessions[] | select(.splitAgentSession) | .splitAgentSession.id'

# forget this pane's conversation (it restores as a plain agent again)
rookctl session agent claude --clear --target "$ROOK_SESSION_ID"

# report one by hand (normally the agent's own SessionStart hook does this, with --from-hook)
rookctl session agent claude --id "$CONVERSATION_ID" --target "$ROOK_SESSION_ID"
```

A report is accepted only from the pane's own agent, so a nested `claude -p` you spawn cannot overwrite the
pane's conversation — that call returns ok and writes nothing.

## Zoom a terminal surface by control id

```bash
# Fill the window with the active terminal surface; call again to leave zoom.
rookctl surface zoom

# Zoom the active session's right split pane by id, even if the split is hidden.
sid=${ROOK_SESSION_ID:?}
surface=$(rookctl tree --json |
  jq -r --arg sid "$sid" '.result.tree.workspaces[].sessions[]
    | select(.id == $sid)
    | .surfaces[]
    | select(.kind == "right")
    | .id')
rookctl surface zoom show --target "$surface"
rookctl surface zoom hide --target "$surface"

# Read the current zoom back (the zoomed surface's control id; null when nothing is zoomed).
rookctl tree --json | jq -r '.result.tree.zoomedSurface'
```

`surface zoom` is not `window zoom`: it does not move/resize the macOS window and must not change split
ratios, sidebar state, focus, or split/scratch visibility. Surface ids come from `tree --json`.

## Navigate and manage windows

```bash
rookctl session go --to next            # step selection to the next session
rookctl session go --to next-attention  # jump to the next blocked/completed session
w=$(rookctl window new "scratch" --json | jq -r '.result.id')
rookctl window resize "$w" --width 1200 --height 800
rookctl window move "$w" --x 100 --y 100 --display 0
rookctl window zoom "$w"                 # maximize-to-screen toggle (call again to restore)
rookctl window fullscreen "$w"           # native macOS full screen toggle (⌃⌘F / green button)
rookctl window minimize "$w" on          # park it in the Dock (off restores; no mode = toggle)
rookctl window select "$w"
```

Build a set of windows without any of them flashing on screen and stealing focus:

```bash
for p in api web worker; do
  rookctl window new "$p" --minimized >/dev/null
done
```

## Park a window and restore it exactly (record-then-restore)

`window list`'s `minimized` is the read side of `window minimize`, so a script can put a window away and
put it back only if it was visible to begin with. A minimized window still reports its `geometry` (the
frame it will come back to), so the frame round-trips while it is parked.

```bash
w=$(rookctl window list --json | jq -r '.result.windows[] | select(.active) | .id')

# record BOTH bits of state before touching anything
was_min=$(rookctl window list --json | jq -r --arg w "$w" \
  '.result.windows[] | select(.id == $w) | .minimized // false')
frame=$(rookctl window list --json | jq -c --arg w "$w" \
  '.result.windows[] | select(.id == $w) | .geometry')

rookctl window minimize "$w" on          # ...do the work with it out of the way...

# restore: only un-minimize if it was not already parked, then put the frame back
[ "$was_min" = "true" ] || rookctl window minimize "$w" off
rookctl window move "$w" --x "$(echo "$frame" | jq -r .x)" --y "$(echo "$frame" | jq -r .y)" \
  --display "$(echo "$frame" | jq -r .display)"
```

Because the mode is explicit (`on`/`off`), this is idempotent without reading first — the read is only
needed to know whether restoring is wanted at all. `window minimize` on a natively full-screen window is
an ERROR, not a silent no-op, so check `fullscreen` first if that is reachable in your flow.

## Reload the keymap after editing it

```bash
$EDITOR ~/.config/rook/keymap.conf
rookctl keymap reload          # prints the parse-diagnostic count (0 = clean)
```

## Diagnose a shortcut that "should work but doesn't"

`keymap reload` only gives you a count. `keymap list` shows what each chord actually resolved to AND what
the menu bar is really carrying — the two halves are meant to be compared, because SwiftUI rebuilds the
menu only on the next app activation.

```bash
rookctl keymap list            # actions (* = overridden, - = keyless), commands, diagnostics, menu
```

```bash
# what did the keymap resolve for this action?
rookctl keymap list --json | jq -r \
  '.result.keymap.actions[] | select(.action == "next_session") | .chord'

# who is holding that chord in the LIVE menu bar? (more than one row = a hijack)
rookctl keymap list --json | jq -r \
  '.result.keymap.menu[] | select(.chord == "cmd+opt+down")
   | "\(.menu) ▸ \(.title)  \(.selector // "-")  enabled=\(.enabled != false)"'

# every action whose resolved chord no NON-disabled menu item is carrying
rookctl keymap list --json | jq -r '
  (.result.keymap.menu // [] | map(select(.enabled != false) | .chord)) as $live
  | .result.keymap.actions[] | select(.chord != null and (.chord | IN($live[]) | not))
  | "\(.action)  \(.chord)"'

# parse problems, line 0 = a whole-file / cross-section problem (e.g. a chord collision)
rookctl keymap list --json | jq -r '.result.keymap.diagnostics[] | "\(.line): \(.message)"'
```

Read the mismatches like this: a `selector` that is not `menuAction:` is a stock AppKit item that took
the chord; `enabled=false` means the item is disabled and its chord is INERT (AppKit consumes the key and
fires nothing, not even a same-chord enabled sibling — with the dashboard open most items are gated this
way); and an action whose chord appears in no live menu row at all usually just means the menu has not
rebuilt yet — switch away from Rook and back, then re-run.

## Change a ghostty setting Rook does not expose

```bash
$EDITOR ~/.config/rook/ghostty.conf   # e.g. add: macos-option-as-alt = true
rookctl config reload                 # apply it; prints the diagnostic count (0 = clean)
```

`ghostty.conf` is scoped to Rook and overrides the bundled defaults and your global
`~/.config/ghostty/config`; Rook's own Settings (font, theme, opacity, scroll) still win. Full key
reference: https://ghostty.org/docs/config

## Set the terminal theme

The app default is the bundled `rook` theme; the "default ghostty" option (no theme) is ghostty's
own built-in colors.

```bash
rookctl theme list                         # bundled themes, the current one marked *
rookctl theme list --json | jq -r '.result.themes[]'   # just the names
rookctl theme set "Dracula"                # set + persist it app-wide (unknown name errors)
rookctl theme set "Rook"                 # back to the app default theme
rookctl theme set                          # ghostty's built-in default (no theme)

# follow the macOS Light/Dark appearance automatically — setting a dark theme starts tracking:
rookctl theme set --dark "Rook"          # light side seeds from the current theme
rookctl theme set "Builtin Light"          # while tracking, a name replaces the LIGHT side (pair kept)
rookctl theme list --json | jq '.result | {sync, light, dark}'   # inspect the sync state
rookctl theme set --dark none              # stop tracking; the light theme stays as the single theme
```

## Targeting another window's tree

```bash
rookctl tree --json --window work          # the "work" window's tree (prefix match)
rookctl session new --window work --cwd "$HOME"
```
