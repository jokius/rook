#!/usr/bin/env bash
# Watch upstream (umputun/agterm) WITHOUT following it.
#
# Model: this is OUR terminal. `master` is our own line of development — we do NOT rebase onto
# upstream, and we do NOT inherit its design decisions. We cherry-pick the occasional useful commit
# (a bug fix, a libghostty bump) when WE decide it's worth taking. Everything else we ignore.
#
# Usage:
#   scripts/upstream.sh              list upstream commits since our last review (the watermark)
#   scripts/upstream.sh list all     list EVERY upstream commit we haven't taken (ignore the watermark)
#   scripts/upstream.sh <sha>        inspect one upstream commit (stat + message)
#   scripts/upstream.sh diff <sha>   full diff of one upstream commit
#   scripts/upstream.sh pick <sha>   cherry-pick it onto our master, then run the gate
#   scripts/upstream.sh mark [<sha>] record the watermark (default: upstream/master tip) so the next
#                                    sync doesn't re-walk everything we already triaged
#
# Watermark: scripts/upstream-reviewed holds the newest upstream commit we've TRIAGED (taken, re-
# implemented on our own line, or consciously declined). `list` shows only what landed AFTER it, so a
# sync starts from the delta instead of the whole divergence. Per-commit take/have/skip decisions live
# in the sync ledger (~/.claude/plans/rook/), not here.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

git fetch --quiet upstream master

reviewed_file="scripts/upstream-reviewed"
reviewed_sha="$(grep -vE '^[[:space:]]*(#|$)' "$reviewed_file" 2>/dev/null | head -1 | awk '{print $1}' || true)"

case "${1:-list}" in
list)
    if [[ -n "$reviewed_sha" && "${2:-}" != "all" ]]; then
        echo "==> upstream commits since our last review ($reviewed_sha):"
        echo "    (everything at or before that SHA was triaged — see the sync ledger for the decisions;"
        echo "     'scripts/upstream.sh list all' shows the full un-taken list, watermark ignored)"
        echo
        git log --oneline --no-decorate "${reviewed_sha}..upstream/master" || echo "    (none — nothing new)"
    else
        echo "==> upstream commits we have NOT taken:"
        echo "    (already cherry-picked ones are filtered out by patch-id)"
        echo
        # --cherry-pick drops commits whose patch we already carry, so a picked commit stops showing up
        git log --oneline --no-decorate --cherry-pick --right-only HEAD...upstream/master || echo "    (none — nothing new)"
    fi
    echo
    echo "inspect:   scripts/upstream.sh <sha>"
    echo "full diff: scripts/upstream.sh diff <sha>"
    echo "take it:   scripts/upstream.sh pick <sha>"
    echo "mark done: scripts/upstream.sh mark   (advance the watermark to the current tip)"
    ;;

mark)
    sha="$(git rev-parse "${2:-upstream/master}")"
    short="$(git rev-parse --short "$sha")"
    subject="$(git log -1 --format='%s' "$sha")"
    {
        echo "# Upstream review watermark — the newest upstream/agterm commit we have TRIAGED"
        echo "# (taken, re-implemented on our own line, or consciously declined)."
        echo "# 'scripts/upstream.sh list' shows only commits AFTER this SHA."
        echo "# Advance with: scripts/upstream.sh mark [<sha>]  (default: upstream/master tip)."
        echo "# Per-commit take/have/skip decisions live in the sync ledger (~/.claude/plans/rook/)."
        echo "$sha  # $short $subject"
    } > "$reviewed_file"
    echo "==> watermark set to $short — $subject"
    ;;

diff)
    git show "${2:?usage: scripts/upstream.sh diff <sha>}"
    ;;

pick)
    sha="${2:?usage: scripts/upstream.sh pick <sha>}"
    if ! git diff-index --quiet HEAD --; then
        echo "!! working tree is dirty — commit or stash first." >&2
        exit 1
    fi
    echo "==> cherry-picking $sha onto our master…"
    git cherry-pick "$sha"

    echo
    echo "==> gate: swift test / make build / make lint"
    swift test --package-path rookCore
    make build
    make lint

    echo
    echo "==> taken. Push when ready:  git push origin master"
    ;;

*)
    git show --stat "$1"
    ;;
esac
