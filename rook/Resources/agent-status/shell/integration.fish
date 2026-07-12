# rook-agent-status — shell integration for fish.
# Sets the rook session's agent-status indicator to `active` while a coding
# agent runs as a foreground command, and back to `idle` at the next prompt.
# Source this from your ~/.config/fish/config.fish.
#
# Which commands count as agents is a regex, override before sourcing to taste:
#   set -g ROOK_AGENT_RE '^(gemini|cursor-agent|my-agent)([[:space:]]|$)'
#
# Claude Code and Codex are intentionally NOT in the default list — their own
# hooks drive finer per-turn state, which the coarse process-level active/idle
# here would only fight. Add either here if you rely on the shell integration
# alone for it.
#
# Every entry point is best-effort and a clean no-op outside rook (guarded by
# $ROOK_SESSION_ID), so sourcing it from a non-rook shell does nothing.

if not set -q ROOK_SESSION_ID
    return 0 2>/dev/null
end

# Locate rook-agent-status.sh relative to this file
set -l _ags_dir (dirname (dirname (status filename)))
if not set -q ROOK_AGENT_BIN
    set -g ROOK_AGENT_BIN "$_ags_dir/rook-agent-status.sh"
end

if not set -q ROOK_AGENT_RE
    set -g ROOK_AGENT_RE '^(gemini|cursor-agent|aider|opencode|crush|goose)([[:space:]]|$)'
end

function _ags_preexec --on-event fish_preexec
    if string match -r -q $ROOK_AGENT_RE $argv[1]
        $ROOK_AGENT_BIN active --blink
        set -g _ags_active 1
    end
end

function _ags_precmd --on-event fish_prompt
    if set -q _ags_active
        $ROOK_AGENT_BIN idle
        set -e _ags_active
    end
end
