#!/usr/bin/env bash
# Run the host-free rookCore unit tests (no Xcode, no libghostty, no Metal).
set -euo pipefail
cd "$(dirname "$0")/../rookCore"
swift test
