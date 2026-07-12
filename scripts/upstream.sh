#!/usr/bin/env bash
# Watch upstream (umputun/agterm) WITHOUT following it.
#
# Model: this is OUR terminal. `master` is our own line of development — we do NOT rebase onto
# upstream, and we do NOT inherit its design decisions. We cherry-pick the occasional useful commit
# (a bug fix, a libghostty bump) when WE decide it's worth taking. Everything else we ignore.
#
# Usage:
#   scripts/upstream.sh              list upstream commits we haven't taken
#   scripts/upstream.sh <sha>        inspect one upstream commit (stat + message)
#   scripts/upstream.sh diff <sha>   full diff of one upstream commit
#   scripts/upstream.sh pick <sha>   cherry-pick it onto our master, then run the gate
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

git fetch --quiet upstream master

case "${1:-list}" in
list)
    echo "==> upstream commits we have NOT taken:"
    echo "    (already cherry-picked ones are filtered out by patch-id)"
    echo
    # --cherry-pick drops commits whose patch we already carry, so a picked commit stops showing up
    git log --oneline --no-decorate --cherry-pick --right-only HEAD...upstream/master || echo "    (none — nothing new)"
    echo
    echo "inspect:   scripts/upstream.sh <sha>"
    echo "full diff: scripts/upstream.sh diff <sha>"
    echo "take it:   scripts/upstream.sh pick <sha>"
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
    swift test --package-path agtermCore
    make build
    make lint

    echo
    echo "==> taken. Push when ready:  git push origin master"
    ;;

*)
    git show --stat "$1"
    ;;
esac
