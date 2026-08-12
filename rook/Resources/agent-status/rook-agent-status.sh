#!/usr/bin/env bash
# rook-agent-status — set the current rook session's agent-status indicator.
#
#   rook-agent-status.sh active            # agent is busy
#   rook-agent-status.sh completed         # agent finished a turn
#   rook-agent-status.sh blocked  --blink  # agent is waiting on you (pulse for attention)
#   rook-agent-status.sh idle              # clear the indicator
#
# States: idle | active | completed | blocked. An optional --blink / --auto-reset
# (and any further args) is forwarded verbatim to `rookctl session status`.
#
# Outside rook this is a silent no-op, so it is safe to call from any hook.
#
# As a hook it must never interfere with the agent: stdout/stderr are suppressed
# (Claude Code injects a UserPromptSubmit/SessionStart hook's stdout into the
# prompt context) and it always exits 0 (a non-zero exit can block the turn).
# The ONE exception is the quit-time drain below, where blocking the turn is the
# whole point: with --drainable passed (PostToolUse only) and rook's shutdown flag
# on disk, it prints the warning on stderr and exits 2 so the model sees it.
#
# rookctl resolution order (the binary that talks to the control socket):
#   1. $ROOKCTL — an explicit override the caller set.
#   2. the absolute bundled-binary path the installer bakes in: the installer
#      rewrites the ROOKCTL default below to rook.app's Contents/MacOS/rookctl,
#      so the hook fires even when the CLI was never symlinked into PATH.
#   3. `rookctl` on PATH — the fallback when nothing above resolved.
set -u

[ -n "${ROOK_SESSION_ID:-}" ] || exit 0   # not inside rook: nothing to do

# --socket is a SUBCOMMAND option, so it must come AFTER `session status`, not before
# it. Pass it only when ROOK_SOCKET is set (the app injects it alongside the id).
state=$1
shift

# Quit-time drain: rook drops a one-line flag file next to the control socket when it is about to close
# and waits a bounded time for mid-turn agents to wrap up. `exit 2` on a PostToolUse hook is what feeds
# the message back to the MODEL as a blocking result — the only channel an agent inside a tool loop can
# actually observe (an events poll, a notification and a pty write all reach nobody mid-turn).
#
# `--drainable` gates this, and the installer puts it on PostToolUse ALONE: on UserPromptSubmit an
# `exit 2` erases the user's prompt, and on Stop it forbids the agent from stopping — the exact opposite
# of what a drain wants. The flag rides argv because PostToolUse and UserPromptSubmit are otherwise
# argv-identical, and the alternative (reading `hook_event_name` off the stdin payload) would put a
# stdin slurp back on the per-tool-call hot path this script was tuned to keep fork-free.
#
# Cost when idle: one `[` and one `read`, both builtins. No `date` (a fork per tool call, and bash 3.2
# — what macOS ships — has no $EPOCHSECONDS), so the flag carries no deadline: rook creates it for the
# duration of the drain and removes it on cancel and at launch.
drainable=
drain_args=()
for arg in "$@"; do
  case $arg in
    --drainable) drainable=1 ;;
    *) drain_args+=("$arg") ;;
  esac
done
set -- "${drain_args[@]+"${drain_args[@]}"}"

if [ -n "$drainable" ] && [ -n "${ROOK_SOCKET:-}" ]; then
  drain_flag="${ROOK_SOCKET%/*}/shutdown"
  if [ -f "$drain_flag" ]; then
    drain_message=''
    read -r drain_message < "$drain_flag" || true
    [ -n "$drain_message" ] || drain_message='rook is closing this terminal. Wrap up now.'
    printf '%s\n' "$drain_message" >&2
    exit 2
  fi
fi

# `Stop` means the main thread ended its TURN, not that the work is DONE. In a swarm the lead hands the
# turn back while its backgrounded teammates keep grinding ("waiting for reports, then the gate") — and a
# `completed --auto-reset` there lights the sidebar's done-checkmark and calls you over for nothing. The
# hook's JSON payload on stdin lists that work in `background_tasks`, so when at least one entry is still
# LIVE we report `active --blink` instead. Nothing has to re-light the checkmark afterwards: Claude Code
# wakes the main thread when the last agent lands, and its next `Stop` carries an empty `background_tasks`.
#
# LIVE = `type` is `subagent` (a Task/teammate) or `workflow` (an orchestrator), AND `status` is not one of
# the terminal values. Testing `status = running` instead would MISS work: the field also takes `pending`
# and `backgrounded`. And `type = shell` (a Bash `run_in_background`) is deliberately NOT live — a
# `bun run dev` sits there for hours and would park the row on `active` forever, which is the one reason
# this cannot just ask whether the array is non-empty.
#
# Both fields must match on the SAME entry, which is why this walks the array by INDEX instead of
# grepping the payload: with a hung `bun run dev` next to a finished subagent, `"type":"subagent"` and
# `"status":"running"` both appear — in DIFFERENT objects — and a substring match would park the row on
# `active` forever.
#
# `plutil` parses the JSON properly; it is always present on macOS, and the Codex adapter in this same
# package already relies on it. Anything it cannot parse yields an empty value, i.e. report anyway — a
# payload rook does not understand must never silence the indicator.
#
# The gate is `state = completed` and nothing else: that is the ONLY state this rewrites, and narrowing
# it there means the hot path — an `active` on every single tool call — no longer reads stdin or forks
# `plutil` at all. `blocked` is likewise never rewritten: a question waiting on you outranks background work.
#
# Reading stdin is gated on $CLAUDECODE — set only in a Claude Code hook's environment — plus a
# non-tty stdin, so the other callers (the shell integration, the Codex adapter which parses the same
# stdin itself, the Pi extension) never block on a `cat` of a pipe nobody closes.
#
# Deliberate trade-off: a lead that ends its turn to ask YOU something while teammates are still running
# shows `active` instead of the checkmark. Today the row lies the other way (it calls you when it is far
# too early), and a person pulled over for nothing costs more than a question noticed a minute late.
if [ "$state" = completed ] && [ -n "${CLAUDECODE:-}" ] && [ ! -t 0 ]; then
  payload=$(cat 2>/dev/null) || payload=''

  i=0
  while [ "$i" -lt 64 ]; do   # a cap, so a payload plutil reads oddly cannot spin here
    printf '%s' "$payload" | /usr/bin/plutil -extract "background_tasks.$i" raw -o - - >/dev/null 2>&1 || break
    task_type=$(printf '%s' "$payload" | /usr/bin/plutil -extract "background_tasks.$i.type" raw -o - - 2>/dev/null) || task_type=''
    task_status=$(printf '%s' "$payload" | /usr/bin/plutil -extract "background_tasks.$i.status" raw -o - - 2>/dev/null) || task_status=''
    live=
    case $task_type in
      subagent|workflow)
        case $task_status in
          completed|failed|cancelled|stopped) ;;   # terminal: this one is done
          *) live=1 ;;                             # running / pending / backgrounded / anything new
        esac
        ;;
    esac
    if [ -n "$live" ]; then
      state=active
      # keep every other flag the caller passed; `--auto-reset` is meaningless for `active`
      status_args=()
      blink_passed=
      for arg in "$@"; do
        case $arg in
          --auto-reset) ;;
          --blink) blink_passed=1; status_args+=("$arg") ;;
          *) status_args+=("$arg") ;;
        esac
      done
      [ -n "$blink_passed" ] || status_args+=(--blink)
      set -- "${status_args[@]+"${status_args[@]}"}"
      break
    fi
    i=$((i + 1))
  done
fi

# forward the pane discriminators when the app injected them: each session surface
# (main/split/scratch) sets its own ROOK_PANE (the role) plus ROOK_PANE_ID (a stable
# per-surface token). the role can go stale — a split survivor promoted into the main pane
# keeps its baked `right` — so we also forward the token as --pane-id, which the app resolves
# to the surface's CURRENT slot and lets override the stale role. both are validated
# rookctl-side, so pass them through verbatim. the ${arr[@]+..} guard keeps the empty-array
# expansion safe under `set -u` on bash 3.2.
pane_args=()
[ -n "${ROOK_PANE:-}" ] && pane_args+=(--pane "$ROOK_PANE")
[ -n "${ROOK_PANE_ID:-}" ] && pane_args+=(--pane-id "$ROOK_PANE_ID")

if [ -n "${ROOK_SOCKET:-}" ]; then
  "${ROOKCTL:-rookctl}" session status "$state" \
    --target "$ROOK_SESSION_ID" --socket "$ROOK_SOCKET" \
    "${pane_args[@]+"${pane_args[@]}"}" "$@" >/dev/null 2>&1 || true
else
  "${ROOKCTL:-rookctl}" session status "$state" \
    --target "$ROOK_SESSION_ID" "${pane_args[@]+"${pane_args[@]}"}" "$@" >/dev/null 2>&1 || true
fi
exit 0
