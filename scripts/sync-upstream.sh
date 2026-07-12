#!/usr/bin/env bash
# Sync this fork with upstream (umputun/agterm).
#
# Model: the fork is "upstream master + our patches on top". This script fetches upstream,
# shows what's new, rebases our patches onto it, runs the full gate, and force-pushes the fork.
# `git rerere` (enabled in this clone) replays conflict resolutions we've already made, so the
# same recurring conflicts (enum cases, case lists, doc counters) mostly resolve themselves.
#
# Usage: scripts/sync-upstream.sh [--dry-run]
#   --dry-run   only report what's new upstream and whether our patches still rebase cleanly
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

echo "==> fetching upstream…"
git fetch upstream master

NEW=$(git rev-list --count HEAD..upstream/master)
if [[ "$NEW" -eq 0 ]]; then
    echo "==> up to date — no new upstream commits."
    exit 0
fi

echo
echo "==> $NEW new upstream commit(s):"
git log --oneline --no-decorate HEAD..upstream/master
echo
echo "==> our patches currently on top of upstream:"
git log --oneline --no-decorate upstream/master..HEAD || true
echo

if [[ "$DRY_RUN" == true ]]; then
    echo "==> dry-run: testing whether our patches still rebase cleanly…"
    if git rebase upstream/master >/dev/null 2>&1; then
        git rebase --abort 2>/dev/null || true
        # the rebase succeeded, so it moved HEAD; put us back where we were
        git reset --hard "@{1}" >/dev/null 2>&1 || true
        echo "==> clean: our patches rebase without conflicts."
    else
        echo "!! conflicts in:"
        git diff --name-only --diff-filter=U || true
        git rebase --abort 2>/dev/null || true
        echo "==> run without --dry-run to rebase and resolve."
    fi
    exit 0
fi

# refuse to rewrite history over uncommitted work
if ! git diff-index --quiet HEAD --; then
    echo "!! working tree is dirty — commit or stash first." >&2
    exit 1
fi

echo "==> rebasing our patches onto upstream/master (rerere replays known resolutions)…"
if ! git rebase upstream/master; then
    echo
    echo "!! conflicts. Resolve them, then:  git rebase --continue"
    echo "   rerere may have already staged known resolutions — check: git status"
    echo "   bail out with:  git rebase --abort"
    exit 1
fi

echo
echo "==> gate: swift test / make build / make lint"
swift test --package-path agtermCore
make build
make lint

echo
echo "==> pushing fork (force-with-lease: rebase rewrote our commits)"
git push --force-with-lease origin master

echo "==> done — fork is upstream + our patches, gate green."
