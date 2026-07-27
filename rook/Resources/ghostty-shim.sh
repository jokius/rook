#!/bin/sh
# Bundled at Contents/MacOS/ghostty (see the Bundle rookctl CLI post-build phase).
#
# rook links libghostty, it does not ship the ghostty BINARY — but ghostty's bundled shell
# integration shells out to one thing at runtime: `"$GHOSTTY_BIN_DIR/ghostty" +ssh-cache`, the
# "this host already has our terminfo" memo its ssh() wrapper keeps (Resources/ghostty/
# shell-integration/*/…, enabled by ssh-terminfo in ghostty-defaults.conf). libghostty sets
# GHOSTTY_BIN_DIR to the app's Contents/MacOS at shell spawn, and the wrapper hardcodes the
# `ghostty` name — hence a shim, under that name, right there.
#
# Without it the probe just fails: every single `ssh` re-uploads terminfo over a fresh
# connection (a visible stall plus a "Setting up xterm-ghostty terminfo on …" line), so the
# feature works but is loud. Anything other than +ssh-cache exits 1 — this is not a ghostty.
#
# ponytail: the memo is host-only, with no expiry and no terminfo version — a host that loses
# its ~/.terminfo (rebuild, fresh home) keeps the stale hit until this file is deleted. Record
# a terminfo hash alongside the host if that ever bites.
set -eu

# Upstream ghostty REPLACED this whole dance after our pinned revision: the wrapper there is just
# `ghostty +ssh -- "$@"`, with terminfo upload and caching inside the binary we don't have. A
# GHOSTTY_REV bump would therefore hand us `+ssh` and, without this arm, ssh would EXIT 1 and never
# connect. Degrade to a plain ssh instead: no terminfo upload (that is the bump's job to re-solve —
# see .claude/rules/libghostty.md), but the user's ssh keeps working.
if [ "${1-}" = "+ssh" ]; then
    for arg in "$@"; do
        shift
        [ "$arg" = "--" ] && break
    done
    exec ssh "$@"
fi

[ "${1-}" = "+ssh-cache" ] || exit 1

# same state dir as the rest of rook: ROOK_STATE_DIR when set (dev/test isolation), else app support.
cache="${ROOK_STATE_DIR:-$HOME/Library/Application Support/rook}/ssh-terminfo-hosts"

case "${2-}" in
    --host=*)
        # exit 0 = cached (wrapper keeps TERM=xterm-ghostty and skips the upload)
        grep -qxF "${2#--host=}" "$cache" 2>/dev/null
        ;;
    --add=*)
        host="${2#--add=}"
        mkdir -p "$(dirname "$cache")"
        grep -qxF "$host" "$cache" 2>/dev/null || printf '%s\n' "$host" >>"$cache"
        ;;
    *)
        exit 1
        ;;
esac
