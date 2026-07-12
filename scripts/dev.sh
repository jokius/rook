#!/usr/bin/env bash
# Build and (re)launch an ISOLATED dev instance, side by side with the deployed ~/Applications/rook.app.
#
# The Debug build already carries its own bundle id (com.rook.app.debug), so it is a separate app to
# LaunchServices. State and the control socket, however, are PATH-based, not bundle-id-derived — without
# ROOK_STATE_DIR a dev launch would read and write the REAL workspaces.json and steal the deployed app's
# socket. The state dir lives under /tmp because a unix socket path caps at ~104 bytes.
set -euo pipefail
cd "$(dirname "$0")/.."

STATE_DIR="${ROOK_DEV_STATE_DIR:-/tmp/rook-dev}"
APP="$PWD/build/DerivedData/Build/Products/Debug/rook.app"
BIN="$APP/Contents/MacOS"

[ "${FRESH:-}" = "1" ] && rm -rf "$STATE_DIR"

./scripts/setup.sh
xcodegen generate
xcodebuild -project rook.xcodeproj -scheme rook -configuration Debug \
  -derivedDataPath build/DerivedData build

# Kill only the PREVIOUS DEV instance, matched by its build path — the deployed daily driver and its
# live sessions are never touched. (A bare `pkill rook` would kill both.)
pkill -f "^$BIN/rook$" 2>/dev/null || true

# Seed the dev config from the real one on first run, so the keymap and custom commands work. Later
# edits inside the dev instance stay local to it; FRESH=1 wipes the state dir and re-seeds.
mkdir -p "$STATE_DIR/config"
for f in keymap.conf ghostty.conf restore-denylist.conf; do
  if [ -f "$HOME/.config/rook/$f" ] && [ ! -f "$STATE_DIR/config/$f" ]; then
    cp "$HOME/.config/rook/$f" "$STATE_DIR/config/$f"
  fi
done

# PATH puts the freshly built rookctl first, so keybound custom commands drive THIS instance rather
# than the deployed one on /usr/local/bin.
open -n --env ROOK_STATE_DIR="$STATE_DIR" \
  --env PATH="$BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
  "$APP"

echo "dev instance up — state $STATE_DIR, socket $STATE_DIR/rook.sock"
echo "drive it: $BIN/rookctl tree --socket $STATE_DIR/rook.sock"
