#!/usr/bin/env bash
# rook-agent-session — tell rook which conversation this agent is on, so a restart can RESUME it.
#
#   rook-agent-session.sh claude    # from Claude Code's SessionStart hook
#   rook-agent-session.sh codex     # from Codex's SessionStart hook
#
# The conversation id is the one thing rook cannot observe: the pane's foreground argv is just
# `claude`, and the agent keeps its id out of the environment. It reaches us only here, in the hook's
# JSON payload on stdin — which is passed straight through to `rookctl session agent --from-hook`, so
# this script needs no `jq` and does no parsing of its own.
#
# rookctl fills in the rest from the environment it inherits: the pane from $ROOK_PANE and the agent's
# config root from $CLAUDE_CONFIG_DIR / $CODEX_HOME (which is what makes a work-vs-personal Claude
# profile resume against the profile the conversation actually lives in).
#
# Outside rook this is a silent no-op, so it is safe to call from any hook. As a hook it must never
# interfere with the agent: stdout/stderr are suppressed (Claude Code injects a SessionStart hook's
# stdout into the prompt context) and it always exits 0 (a non-zero exit can block the turn).
#
# ROOKCTL resolution matches rook-agent-status.sh: an explicit $ROOKCTL, else the absolute path the
# installer bakes in below, else `rookctl` on PATH.
set -u

[ -n "${ROOK_SESSION_ID:-}" ] || exit 0   # not inside rook: nothing to do

kind=${1:-}
[ -n "$kind" ] || exit 0

# --socket is a SUBCOMMAND option, so it must come AFTER `session agent`.
socket_args=()
[ -n "${ROOK_SOCKET:-}" ] && socket_args=(--socket "$ROOK_SOCKET")

"${ROOKCTL:-rookctl}" session agent "$kind" --from-hook \
  --target "$ROOK_SESSION_ID" "${socket_args[@]+"${socket_args[@]}"}" >/dev/null 2>&1 || true
exit 0
