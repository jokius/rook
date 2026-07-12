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

# forward the pane discriminator when the app injected it: each session surface
# (main/split/scratch) sets its own ROOK_PANE so a status set from a background pane
# lands on that pane. it is validated rookctl-side, so pass it through verbatim. the
# ${arr[@]+..} guard keeps the empty-array expansion safe under `set -u` on bash 3.2.
pane_args=()
[ -n "${ROOK_PANE:-}" ] && pane_args=(--pane "$ROOK_PANE")

if [ -n "${ROOK_SOCKET:-}" ]; then
  "${ROOKCTL:-rookctl}" session status "$state" \
    --target "$ROOK_SESSION_ID" --socket "$ROOK_SOCKET" \
    "${pane_args[@]+"${pane_args[@]}"}" "$@" >/dev/null 2>&1 || true
else
  "${ROOKCTL:-rookctl}" session status "$state" \
    --target "$ROOK_SESSION_ID" "${pane_args[@]+"${pane_args[@]}"}" "$@" >/dev/null 2>&1 || true
fi
exit 0
