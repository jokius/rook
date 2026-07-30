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

# a SUBAGENT's turn is not the session's turn state. Claude Code fires the SAME status hooks INSIDE a
# subagent (the Task tool) as on the main thread, and stamps them with the SAME session_id — so a flock
# of working subagents keeps re-asserting `active` over the `completed` the main thread already
# reported, and the sidebar row lies about whose turn it is. The only discriminator is the hook's JSON
# payload on stdin: `agent_type` is ABSENT on the main thread (it defaults to an unset
# mainThreadAgentType) and carries the subagent's own type — `Explore`, `general-purpose`, `teammate` —
# inside one. So drop a subagent's report.
#
# It must be the TOP-LEVEL `agent_type` and nothing else: a `Stop` payload also lists the session's
# `background_tasks`, and a BACKGROUNDED subagent's entry there carries its own nested `agent_type` — so
# a substring match on the raw payload reads the MAIN thread's Stop as a subagent's and swallows the
# `completed` (observed live: the row stayed on active+blink after the turn ended). `plutil` parses the
# JSON and extracts exactly the top-level key; it is always present on macOS, and the Codex adapter in
# this same package already relies on it. Anything it cannot parse yields an empty value, i.e. report
# anyway — a payload rook does not understand must never silence the indicator.
#
# `blocked` is NEVER dropped: a subagent's permission prompt is a real question waiting on you (and
# answering it clears the glyph through the pane's own keystroke, not through a hook).
#
# Reading stdin is gated on $CLAUDECODE — set only in a Claude Code hook's environment — plus a
# non-tty stdin, so the other callers (the shell integration, the Codex adapter which parses the same
# stdin itself, the Pi extension) never block on a `cat` of a pipe nobody closes.
if [ "$state" != "blocked" ] && [ -n "${CLAUDECODE:-}" ] && [ ! -t 0 ]; then
  payload=$(cat 2>/dev/null) || payload=''
  agent_type=$(printf '%s' "$payload" | /usr/bin/plutil -extract agent_type raw -o - - 2>/dev/null) || agent_type=''
  case $agent_type in
    ''|main|main-*) ;;   # the main thread (or a payload carrying no such key)
    *) exit 0 ;;         # a subagent: not this session's turn state
  esac
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
