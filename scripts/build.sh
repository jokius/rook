#!/usr/bin/env bash
# Build a release app.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/setup.sh
xcodegen generate
GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
# version = latest reachable v-tag (About panel / CFBundleShortVersionString);
# builds past the tag keep its version and the GitCommit parenthetical
# disambiguates. Falls back to 0.0.0 when no tag is reachable (shallow CI).
# `|| true` inside the substitution: `git describe` exits 128 with no tags, which
# under `set -e` would abort before the fallback below — swallow it so the empty
# result reaches the `-n` check.
VERSION="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)"
[ -n "$VERSION" ] || VERSION="0.0.0"
xcodebuild -project rook.xcodeproj -scheme rook -configuration Release \
  -derivedDataPath build/DerivedData \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" GIT_COMMIT="$GIT_COMMIT" build

# Re-sign with a stable identity, AFTER xcodebuild returns so Xcode's own final
# code-sign can't clobber it — the same ordering scripts/release.sh relies on.
# project.yml's build phase leaves the bundle AD-HOC, and an ad-hoc signature has
# no stable identity: its designated requirement is the cdhash, which changes on
# every rebuild. macOS keys TCC grants (Accessibility, Automation, Screen
# Recording…) and keychain ACLs off that requirement, so every `make deploy`
# looked like a brand-new app and re-asked for all of them. A real certificate
# keys them to the leaf CN + team instead, so the grants survive rebuilds.
#
# Identity: $ROOK_SIGN_IDENTITY, else `git config rook.signIdentity` (per-clone,
# uncommitted — this is a machine-local choice, not a repo-wide one), else the
# keychain's Developer ID Application, else Apple Development, else stay ad-hoc.
# The last fallback keeps CI and fresh clones building with no certificate at all.
# Pin the identity explicitly if the keychain holds more than one candidate:
# switching between them resets the very TCC grants this is meant to preserve.
APP="build/DerivedData/Build/Products/Release/rook.app"
SIGN_ID="${ROOK_SIGN_IDENTITY:-$(git config rook.signIdentity || true)}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')"
fi
if [ -n "$SIGN_ID" ]; then
  echo "==> signing: $SIGN_ID"
  # inside-out: the nested helper first, then the bundle seals it.
  codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/MacOS/rookctl"
  codesign --force --options runtime \
    --entitlements rook/rook.entitlements --sign "$SIGN_ID" "$APP"
  codesign --verify --deep --strict "$APP"
else
  echo "==> no signing identity found — leaving the build ad-hoc"
fi

echo "built: $APP"
