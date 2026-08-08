<!-- rook-skill -->

# Troubleshooting Rook and reporting problems

Two jobs: (1) diagnose a problem from inside a Rook session, (2) help the user file it on the repo
as a bug (issue) or a feature/question (Discussion) — safely, never posting without approval.

The full user-facing version of the diagnostics below is the repo's `docs/troubleshooting.md`.

## Diagnosing from inside a session

You are inside Rook (`ROOK_ENABLED=1`). Use:

- **Live state** — `rookctl tree --json`, `rookctl window list --json`.
- **Keymap problems** — `rookctl keymap reload` prints the parse-diagnostic count (`0` = clean). A
  non-zero count means `keymap.conf` has problems; the user sees the list in Settings ▸ Key Mapping.
  `rookctl keymap list` is the read side: the config path, every built-in with the chord it resolved to,
  the custom commands, the diagnostics themselves, and the LIVE menu-bar key equivalents — compare the
  last two sections when a chord looks right but does not fire.
- **Ghostty settings** - `rookctl config reload` re-reads the ghostty config and prints the diagnostic
  count (`0` = clean). The count covers every config source, not just `ghostty.conf` (libghostty does not
  record which file a diagnostic came from), so check the Console log for the offending line. `ghostty.conf`
  (next to `keymap.conf`, always loaded) is where Rook customizations go; it overrides the bundled
  defaults, and the global `~/.config/ghostty/config` is NOT loaded unless Settings ▸ General ▸ Use my
  global Ghostty config is on. Rook's Settings (font/theme/opacity/scroll) still win. Use it for keys the UI does not expose, e.g.
  `macos-option-as-alt`. Most keys apply to open panes on reload, but layout keys (`window-padding-*`)
  and spawn-time keys (`term`, `shell-integration-features`) only take effect in a new session/window
  or after a relaunch. Full reference: https://ghostty.org/docs/config
- **Logs** (unified logging, subsystem `com.rook.app`):
  ```bash
  log show --predicate 'subsystem == "com.rook.app"' --info --last 30m
  ```
  Categories: `CustomCommandRunner`, `SettingsModel`, `GhosttyApp`, `NotificationManager`, `ControlServer`.
- **Files** — keymap `~/.config/rook/keymap.conf`; rook-scoped ghostty config
  `~/.config/rook/ghostty.conf`; settings `~/Library/Application Support/rook/settings.json`;
  socket path in `$ROOK_SOCKET`.

### "Keymap editor won't open"

Edit Keymap runs `$VISUAL`/`$EDITOR` (else `vi`) in an overlay via the login shell. The most common
cause is a **GUI editor launched without a blocking flag** (`code`, `subl`, `zed`, `mate`, `cursor`):
it returns immediately, so the overlay flashes shut. Fix: `export EDITOR='code -w'` (the editor's wait
flag) in the shell rc. `$EDITOR`/`$VISUAL` must be **exported** (`export EDITOR=…`, or fish `set -gx
EDITOR …`) so it resolves regardless of your login shell — a non-exported value falls back to `vi`. It
also no-ops with no session selected or an overlay already open.

### "Custom action does nothing"

Causes, in order: a parse error (see the diagnostics); the chord conflicts with a built-in or another
custom command and was dropped to palette-only (it still runs from `⌃⇧P`, tagged `custom`); a reserved
chord (`ctrl+tab`, `ctrl+1`/`ctrl+2`); a modifier-less key (rejected — a custom chord needs a
modifier); it does not fire while a text field (rename/palette/Settings) has focus, though it DOES fire
from a terminal pane or even an emptied window (a launcher command with no session token still works once
every session is closed); it runs in a non-interactive
`/bin/sh -c` (no aliases/functions, a smaller `PATH` — use absolute paths or `$SHELL -lc '…'`); a
non-zero exit posts a failure banner (meaning it DID fire and failed). Reload after edits:
`rookctl keymap reload`.

### "The chord is right in keymap.conf but pressing it does nothing"

`keymap reload` says `0` diagnostics and the file looks correct, yet the key does nothing (or runs the
wrong thing). Use `rookctl keymap list`, which reports TWO halves that are meant to be compared: what the
keymap RESOLVED (`actions`) and what the menu bar is actually carrying (`menu`).

```bash
rookctl keymap list
```

Read it in this order:

1. **Is the action on the chord you expect?** In `actions`, `*` marks an overridden built-in and `-` a
   keyless one. A chord you thought you set but that is not here means the `map` line was skipped — check
   `diagnostics` (a line-0 entry is a whole-file / cross-section problem, e.g. a chord collision between
   two sections, so it prints without a line number).
2. **Is any menu item holding it?** If the chord is in `actions` but appears on NO `menu` row, the menu
   has not rebuilt: SwiftUI defers that to the next app activation. Switch away from Rook and back, then
   re-check.
3. **Is something ELSE holding it?** A `menu` row whose selector is not `menuAction:` is a stock AppKit
   item (`performClose:`, `closeAll:`, …) that won the chord.
4. **Is the item inert?** A row tagged `(disabled)` still CONSUMES the key and fires nothing — not even a
   same-chord enabled sibling. Most File/View/Navigate items are gated, so with the dashboard open the
   menu is largely inert while still holding every chord.

Arrow chords are ordinary chords now (`map cmd+shift+left previous_session` works), with one rule: a
built-in `map` on a bare, modifier-less arrow is rejected (`bare arrow chord … needs a modifier; map
skipped`) — an always-on menu key equivalent has no text-field pass-through, so it would swallow the arrow
in the rename field, the palettes, and Settings. And since the six arrow-bound defaults are now visible to
the conflict checker, re-using one (e.g. `map cmd+opt+up new_session`) is reported as a collision instead
of silently double-binding.

### "An overlay or --command session opens then instantly closes"

The program exited immediately. Check `rookctl session overlay result --json` — `exitCode: 127` is
"command not found", and which command form you used decides whether that can even happen.
`session overlay open` runs its program with the app's GUI `PATH` (the launchd default — no
`/opt/homebrew/bin`) and reads no rc file, so a bare Homebrew or other non-default binary isn't found:
give an absolute path (`/opt/homebrew/bin/htop`) or wrap in a login shell (`zsh -lc 'htop'`).
`session new --command` and `session scratch --command` do NOT have that problem — they run under a login
shell (`<shell> -l -c '<cmd>'`), so your rc files run and `PATH` is yours; a 127 there means the command
really is missing from your own login `PATH` (check the same command in a normal session), not that rook
stripped it. Any OTHER exit code just means the program ran and exited on its own — the overlay/session
closes when its command finishes, by design.

A `--command` session that starts in the wrong directory is the same mechanism seen from the other side:
the login shell runs your rc, and an rc that does a `cd` overrides `--cwd`. Nothing in rook can win that
race — move the `cd` behind an interactive-shell guard in your rc if you need `--cwd` honored.

`invalid shell (expected an absolute path)` from `session new --shell` / `window new --shell` / `quick
--shell` means the value wasn't an absolute path (`fish` instead of `/opt/homebrew/bin/fish`, or a value
carrying a control character); `shell not found or not executable: <path>` means the path doesn't point at
an executable file (a directory counts as not executable here). Both reject before anything is created, so
nothing was half-made. Since `rookctl` fills `--shell` from your `$SHELL` by default, a broken `$SHELL` in
the calling shell produces these too — check `echo "$SHELL"` before blaming the flag.

⌘C/⌘V/⌘A copy/paste/select-all on any layout by default, via two layers.

The **Edit menu** owns them first: its stock Copy/Paste/Select All items carry ⌘C/⌘V/⌘A as menu key
equivalents, which AppKit matches against the character the layout produces. An enabled item consumes the
key before the terminal sees it. The items enable only when the terminal can service them — Copy needs a
selection, Paste needs something pasteable on the clipboard (text, or a file/web URL, which pastes as a
shell-escaped path), Select All needs a live surface. Cut stays disabled for the terminal (it still works in
a text field, such as the inline rename or a palette's search box). Undo and Redo are not in the menu at all:
Rook has no undo, and ⌘Z belongs to File ▸ Reopen Closed Item. Because these are standard menu shortcuts,
⌘C/⌘V/⌘A are NOT rebindable through `ghostty.conf`.

Rook's bundled ghostty defaults are the **fallback**, binding all three to the physical key POSITIONS
(`super+key_c`/`super+key_v`/`super+key_a`), matched by keycode regardless of the character the layout
prints. They fire whenever the menu equivalent does not: on a Russian/Greek/etc. layout the physical C key
yields `с`, so the menu's ⌘C never matches and the keycode bind runs instead; likewise a ⌘C with no
selection leaves the menu item disabled, so the key falls through (and ghostty's `performable:` prefix makes
it a no-op). This is why copy, paste, and select-all all keep working on a non-Latin layout. (ghostty's own
`super+c`/`super+v`/`super+a` match the produced CHARACTER, so alone they would miss there — `super+key_a`
in particular exists because without it ⌘A would silently do nothing on a Cyrillic layout.)

To remap a shortcut ghostty still owns: a physical key name (`key_c`, `key_v`, …) matches by position on
any layout; a bare letter (`c`, `v`) matches the produced character. Edit `~/.config/rook/ghostty.conf`,
then `rookctl config reload`.

### "notify says ok but no notification appears"

Most often the banners toggle is off: Settings ▸ Notifications ▸ "Show notification banners".
The command still succeeds and the sidebar's unseen badge still ticks, so the tell is `result.text` —
banners off makes `notify` answer `badge updated, but "Show notification banners" is off, so no banner
was posted` instead of a bare `ok` (with `--json`, `result.text` present alongside `result.id`).
No note and still no banner means the banner left rook, so look at macOS: System Settings ▸
Notifications ▸ Rook (alerts allowed, Do Not Disturb / a Focus off).
Every posted banner AND every silent drop logs at `.notice`, which `log show` persists, so both cases
are visible in the log (`category == "NotificationManager"`), including the terminal's own OSC 9/777
suppressed because you were typing in the firing pane.

### "rookctl events stopped, or I missed events"

`rookctl events` exits non-zero rather than quietly resubscribing — by design. A consumer that lost its
place has to LEARN it, instead of reading the silence as "nothing happened". Three cursor errors say so,
each returned with `ok:false` but STILL carrying the ring's current anchor in `result.events`, so you can
rebaseline from the same reply once you have decided to:

- `event run changed` — the cursor is from a PREVIOUS app run. The ring lives in the process: it is
  stamped with a fresh run UUID at every launch and nothing survives a restart. Rook was relaunched (or
  you are talking to a different instance's socket); the old run's events are gone.
- `event cursor expired` — the events after your cursor were already evicted. The ring holds the last
  4096 entries, so a consumer that stalls (or a `--limit` loop that never keeps up) falls off the back.
- `event cursor is ahead of the current sequence` — the cursor's sequence is past the ring's newest one.
  Normally a cursor persisted from another ring, or hand-edited state.

Missing events with NO error means you never asked for them: starting with no `--run`/`--after`
subscribes FROM NOW, and there is no history replay. Whatever happened before the first read, or between
a watcher's death and its restart, was never in your stream. Record that gap rather than assuming it was
quiet — see examples.md ▸ "Watch what happens instead of diffing the tree".

`--kind notify` carries the notification's `title` + `body` from both sources (the terminal's own OSC
9/777 and the `notify` command) and is recorded BEFORE the banner gate, so an empty `notify` stream means
nothing was accepted for a session — not that banners are off.

### "I marked workspaces into the focus set and the sidebar did not change"

`workspace focus add` is MARK-ONLY: it never switches the filter on.
That is deliberate — it is what lets a set be built member by member with the whole tree still on screen
(an `add` that applied the filter would collapse the tree onto the first member and hide the rows the
next `add` needs). Nothing narrows until you apply the set:

```bash
rookctl workspace focus add --target a1b2
rookctl workspace focus add --target 7f3c
rookctl workspace filter on            # <- the step that actually applies the set
```

Read the state back rather than guessing: a workspace node's `marked` says it is a member, the tree's
top-level `workspaceFilter` says whether the filter applies, and `focused` is exactly their conjunction.
Several nodes `marked` with no `focused` anywhere means the set is built and unapplied — that is this
problem, and one `workspace filter on` ends it.
Two other ways to see no change: `filter on` with an EMPTY set is a documented no-op (it still answers
`ok`, so check `workspaceFilter` rather than the exit status), and NO workspace row renders at all while
the sidebar is hidden (`sidebarVisible: false`) or in flagged mode (`sidebarMode: "flagged"`), whatever
the filter and the membership say.

### "The workspace filter switched itself off"

Expected, and the marked set is still there.
An INVOLUNTARY jump out of the set — idle auto-follow to a blocked session, attention nav (⌃⌥↑/⌃⌥↓), a
click on a notification banner, the dashboard, the recent-sessions popover — drops only the FLAG, so the
session it jumped to is visible, and KEEPS the set: none of those is the user saying they are done with
their working set.
One `workspace filter on` brings it back (the sidebar's filter toggle does the same, which is exactly why
that button stays live while the filter is off).

A set that came back EMPTY is a different problem: an explicit `workspace focus off` unmarks a workspace,
a DELETED workspace drops out of the set on its own, and the filter switches off with the last member.
Then there is genuinely nothing to re-apply and the set has to be rebuilt with `workspace focus add`.

### "The agent-status glyph updates the wrong session"

One session's glyph blinks/changes while the work is happening in a DIFFERENT session — typically when
the agents run inside tmux (or a tmux-backed session manager like agent-deck). Cause: the working
process inherited another session's `ROOK_SESSION_ID`, and the agent-status hook targets whatever id
it finds in its environment. The usual carrier is a long-lived daemon started from inside a Rook
session — a tmux server captures the spawning shell's `ROOK_*` into its GLOBAL environment
(`tmux show-environment -g | grep ROOK`), and every pane created on that server inherits it, no
matter which client attaches. Diagnose: find the agent's pid and check its real environment —
`ps eww <pid> | tr ' ' '\n' | grep ROOK_SESSION_ID` — if the id is not the session the process
lives in, it leaked. Fix a poisoned tmux server without restarting it:
`for v in ROOK_ENABLED ROOK_PANE ROOK_PANE_ID ROOK_SESSION_ID ROOK_SOCKET ROOK_WINDOW_ID ROOK_WORKSPACE_ID; do tmux set-environment -g -r "$v"; done`,
then restart the affected panes/processes (a respawn is enough; existing processes keep their
inherited copy). Prevent it: start daemons and session managers with the variables scrubbed
(`env -u ROOK_SESSION_ID … <cmd>`, full list in SKILL.md), or from a shell outside rook.

### "The blocked glyph lands on the wrong PANE of the right session"

The session is correct but the status is attributed to the other pane — so the attention navigation and
auto-follow reveal the wrong half of the split. It shows up after a specific sequence: the session's MAIN
pane exits, the split survivor is promoted into the main slot, and you split again. `ROOK_PANE` is baked
into a shell's environment when it spawns and is never rewritten, so the promoted shell still carries
`ROOK_PANE=right`; after the re-split BOTH shells think they are the right pane.

The fix is `ROOK_PANE_ID`, a stable per-surface token the app resolves to the pane's CURRENT slot at the
moment the status is reported. The installed hook forwards it as `session status --pane-id`, and a token
that resolves overrides the stale `--pane`.

**An installed hook is a COPY, so an older installation does not have it.** Re-run Rook ▸ Help ▸ Install
Agent Status Hooks… (idempotent) and restart the affected shells. Check a shell has the token at all:

```bash
echo "${ROOK_PANE:-unset} ${ROOK_PANE_ID:-unset}"     # a pane shell should print a role AND a token
grep -c pane-id ~/.config/rook/agent-status/rook-agent-status.sh   # 0 = the old hook, re-install
```

A shell spawned before the token existed simply falls back to `--pane`, i.e. the old behavior — nothing
breaks, it just stays stale until that shell is restarted.

### "A subagent is working and the row shows `active`"

By design, and it is a REVERSAL of the previous behavior. Claude Code fires the status hooks INSIDE a Task
subagent too, stamped with the SAME `session_id`, so a working subagent keeps the row on `active` exactly
like the main thread does.

The wrapper used to DROP those reports, keyed on the hook payload's `agent_type` (absent on the main
thread, the subagent's own type inside one), because they kept re-asserting `active` over the `completed`
the main thread had already reported. That filter is GONE. The `background_tasks` substitution (below)
fixes that same lie at its source — the one report that was actually wrong — while the filter's price was
losing the signal ENTIRELY: while a swarm grinds, the subagents' hooks are the ONLY hook traffic the
session produces, so the row fell silent exactly when the session was busiest (measured over one minute:
45 dropped subagent reports against 8 from the main thread).

**Known limitation: a subagent's `active` can overwrite the main thread's `blocked`.** If the lead asks
the human a question while its agents keep working, the next agent report pushes the row off `blocked`.
The wrapper cannot fix this alone — it needs a "do not downgrade `blocked`" argument on `session.status`,
which is a separate change — so for now a swarm session reads as "busy" and a question is found by looking
at the pane.

**Setting `blocked` by hand does NOT work around this — do not bother.** The very next `Stop` (that is,
the end of the turn in which you asked the question) hooks straight back into the substitution above: live
`background_tasks` → `active --blink`, and your `blocked` is gone milliseconds later. The only reports
that survive are the ones nothing follows, which is never the case while a swarm is running.

An install predating the removal still DROPS subagent reports (an installed hook is a copy): re-run
Rook ▸ Help ▸ Install Agent Status Hooks…, then check
`grep -c agent_type ~/.config/rook/agent-status/rook-agent-status.sh` (non-zero = the OLD hook, still
filtering).

### "My nested `claude -p` does not move the status"

Also by design, and by a DIFFERENT mechanism than the one above. A nested agent PROCESS — a `claude -p …`
you spawned through Bash — is the main thread of its own session, so its hook payload is indistinguishable
from the pane's own agent's. It used to report `completed` when it finished, while the pane's real agent
was still working. So `session status` runs the same ownership check `session agent` does: `rookctl`
reports its nearest agent ANCESTOR's pid, and the app drops a status whose pid provably differs from the
pane's foreground process, answering `ok` with `ignored: not the pane's agent` and changing nothing.

Two mechanisms, two holes, and neither replaces the other: a nested process reports from its own pid,
while an in-process subagent (Task, teammates) shares the pane's — only the payload's `background_tasks`
says anything about the latter.

**The check is NARROW and fail-OPEN** — it drops a report only when all THREE of these hold, so the
things it could plausibly break are not broken:

1. the call names the CALLER's own session (`--target "$ROOK_SESSION_ID"`, what the hook always passes).
   Flagging ANOTHER session — an orchestrator setting a status on a worker's pane — sends no pid at all
   and is never checked, since the caller's pid says nothing about a pane it is not running in.
2. an AGENT is the pane's foreground process. **Under tmux or ssh it is not** (the wrapper is), so
   ownership is unknowable there and the status passes — reporting from inside tmux works exactly as
   before.
3. the pids differ.

Everything else passes: `rookctl session status` from your own shell or a script (no agent ancestor = no
claim), `--target active`, a pane whose foreground process cannot be read. Losing a `blocked` — your
agent waits on a human while the row stays silent — is worse than one stray `active`.

If a nested run really should surface, report it from the PANE's agent instead of from inside the nested
one:

```bash
rookctl session status active --blink --target "$ROOK_SESSION_ID" --pane "$ROOK_PANE"  # before nesting
```

**Pass `--pane "$ROOK_PANE"` whenever you report by hand** (the installed hook already does). With no pane
the check resolves to the MAIN pane, so an agent reporting from a split or the scratch is measured against
its NEIGHBOUR's foreground process — a mismatch, and the report is dropped. In the main pane it changes
nothing, so passing it is always right.

### "My turn ended but the row shows `active`, not the completed checkmark"

By design, and it is the SECOND mechanism on this seam (the other being the pid ownership check above).
Claude Code's `Stop` event means the main thread ended its TURN, not that the work is
DONE: in a swarm the lead hands the turn back while its backgrounded teammates keep grinding, and the
installed `Stop` → `completed --auto-reset` hook used to light the done-checkmark and call the user over for
nothing. So when the `Stop` payload's `background_tasks` still holds a LIVE entry the wrapper reports
`active --blink` instead, keeping every other flag it was passed and dropping only `--auto-reset`.

**An entry is LIVE when its `type` is `subagent` (a Task or a teammate) or `workflow` (an orchestrator),
AND its `status` is not one of `completed`, `failed`, `cancelled`, `stopped`** — both fields on the SAME
entry. The status test lists the TERMINAL values rather than checking for `running`, because the field also
takes `pending` and `backgrounded`, and a finished entry usually DISAPPEARS from the array rather than
flipping status.

A backgrounded SHELL (`bun run dev`, `tail -f` — `type: "shell"`) is deliberately NOT live: it sits in
`background_tasks` for hours, and treating a non-empty array as "busy" would strand the row on `active`
forever. That is the one and only reason the check cannot just ask whether the array is empty.

Nothing has to re-light the checkmark: Claude Code wakes the main thread when the last agent lands, and its
next `Stop` carries an empty `background_tasks`, which reports the honest `completed --auto-reset`.

**The deliberate trade-off:** if the lead ends its turn to ask the HUMAN something while teammates are still
running, the row shows `active` instead of the checkmark. That is accepted — the row used to lie the other
way (calling you when it was far too early), and a person pulled over for nothing costs more than a question
noticed a minute later. An agent cannot work around it by setting a status itself, either: `Stop` fires
AFTER the agent's last action and overwrites whatever it set, and after `Stop` the agent runs nothing.

**A leftover `active` is stickier than the checkmark it replaced.** `completed --auto-reset` cleared two
cheap ways — visiting the session, or ANY keystroke in the pane. `active` clears by neither: only an
INTERRUPT keystroke (Esc / Ctrl-C in the owning pane), the row's right-click **Clear Status**, or
`rookctl session status idle --target …`. So if the agent is killed right after the turn (⌃D, closing it)
the row keeps pulsing `active` where it used to show a checkmark that a single click erased. Same
stickiness the ordinary `active --blink` from `PostToolUse` has always had — just now reachable at the end
of a turn too.

**Claude Code only.** Codex and Pi report through their own adapters and the shell integration through
`ROOK_AGENT_RE`; none of them carries a `background_tasks` payload, so under them a finished turn lights
the checkmark exactly as before — a Codex-driven swarm will not behave like this.

An install predating this still shows the old behavior (an installed hook is a copy): re-run
Rook ▸ Help ▸ Install Agent Status Hooks…, then check
`grep -c background_tasks ~/.config/rook/agent-status/rook-agent-status.sh` (0 = the old hook).

### "Clicking a path in the terminal does nothing / opens Finder instead of the preview"

⌘-clicking a link routes by what the path IS, and a click that lands on nothing is silently ignored on
purpose (so ordinary prose does not bounce Finder). Check, in order: the file must EXIST — a bare path
is resolved relative to the clicked pane's own working directory (reported by the shell over OSC 7), so
a path printed relative to a DIFFERENT directory resolves to nothing; only `.md`/`.markdown`/`.mdx`
open in the preview panel, everything else is revealed in Finder by design (a terminal renders untrusted
output, so rook never LAUNCHES a file); a directory is revealed, never previewed; and a path under an
automount root (`/net`, `/Network`, `/home`) is ignored outright. A `src/foo.ts:42` style target has its
`:line` suffix stripped and is then revealed like any other non-Markdown file — the line number is
dropped, nothing jumps to it. To put a specific file on screen regardless, drive it directly:
`rookctl session markdown open <path> --target "$ROOK_SESSION_ID"`.

### "Claude Code's question/permission prompt is unresponsive after switching apps"

Known upstream Claude Code bug, NOT rook. Do not file a Rook issue for it. While Claude Code shows
an interactive prompt (a question menu or a permission dialog), switching to another app and back leaves
it deaf to the keyboard (arrows and Return do nothing); the normal prompt and the shell still work. On
refocus Rook sends the standard focus-in report (`ESC[I`, DEC mode 1004); Claude Code's dialog handler
mishandles it. Rook emits correct paired focus-in/focus-out and is already macOS focus-first (the
refocus click is not forwarded into the pty), so the terminal is not at fault. Tracked as
anthropics/claude-code#72188 (mouse-click variant #72273). Workaround: answer before switching away, or
`Esc` the stuck prompt and let it re-ask.

## Reporting: decide bug vs unsupported FIRST

- A **supported** thing misbehaves (a documented command/feature does the wrong thing, a crash, a parse
  bug) → a GitHub **issue**.
- The user wants something **not supported**, or it is a question / idea / "can it do X" → a GitHub
  **Discussion** (category `Ideas` for a feature request, `Q&A` for a question). Do NOT file a feature
  request as a bug.

## Hard rules for filing

1. **Never run any `gh` command without the user's explicit approval in this conversation.** Drafting
   is fine; posting needs a clear go-ahead ("post it").
2. **Check tooling first** — `gh auth status`. If `gh` is missing or not logged in, do NOT install or
   authenticate it. Give the user the prefilled content plus the URL to paste it into:
   - issue: <https://github.com/jokius/rook/issues/new>
   - discussion: <https://github.com/jokius/rook/discussions/new>
3. **Draft first.** Show the user the full title and body, and get explicit approval before any `gh`.
4. **Scrub sensitive content** before showing or posting: API tokens/keys, passwords, internal
   hostnames/IPs, usernames embedded in absolute paths (replace with `~` or `<user>`), private repo
   names, and the contents of a selection / `session.copy` / clipboard. When unsure, ask.
5. **Gather the repro facts yourself** where you can: Rook version (the user reads it from
   Rook ▸ About Rook), `rookctl tree --json` shape, a scrubbed `keymap.conf` excerpt, a scrubbed
   `log show` excerpt.

## Issue template (bug)

```
Title: <short, specific>

What happened: <one or two sentences>
Expected vs actual: <…>
Steps to reproduce:
1. …
2. …
Environment: Rook <version>, macOS <version>
Logs: <scrubbed `log show --predicate 'subsystem == "com.rook.app"'` excerpt>
Config: <scrubbed keymap.conf lines, if keymap-related>
```

File it (only after approval) with `--body-file -` so a multi-line body is not mangled by quoting:

```bash
gh issue create -R jokius/rook --title "<title>" --body-file - <<'EOF'
<body>
EOF
```

## Discussion (feature request / question)

```bash
gh discussion create -R jokius/rook --category "Ideas" --title "<title>" --body-file - <<'EOF'
<body>
EOF
```

Use `--category "Ideas"` for a feature request, `"Q&A"` for a question. Same draft-first, scrub, and
explicit-approval rules apply.
