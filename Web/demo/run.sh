#!/usr/bin/env bash
# Builds the demo app (Web/demo/App) with SwiftUIWeb's browser build and serves it on http://127.0.0.1:${PORT:-8080},
# or runs the browser test with --test.
#
# SWIFTUIWEB_ROOT names the SwiftUIWeb checkout (default: ../SwiftUIWeb next to this repository). The app depends on
# skip-motion as `../skip-motion`, as an app next to this checkout would, so it is built from a copy placed beside a link
# to this checkout, outside it.
set -euo pipefail

web="$(cd "$(dirname "$0")/.." && pwd)"
repository="$(cd "$web/.." && pwd)"
swiftuiweb="${SWIFTUIWEB_ROOT:-$repository/../SwiftUIWeb}"
[[ -x "$swiftuiweb/Tools/run-browser-embedded.sh" ]] || { echo "Set SWIFTUIWEB_ROOT to a SwiftUIWeb checkout." >&2; exit 2; }
swiftuiweb="$(cd "$swiftuiweb" && pwd)"

(cd "$web" && bun install --frozen-lockfile >/dev/null && bun run build >/dev/null)

work="${TMPDIR:-/tmp}/skip-motion-demo"
rm -rf "$work"
mkdir -p "$work"
ln -s "$repository" "$work/skip-motion"
# -L: the app's Web/Resources links to the player this checkout ships (Web/Resources).
cp -RL "$web/demo/App" "$work/MotionDemo"

# The app spells `import SwiftUI` (`-module-alias SwiftUI=SwiftUIWeb`), which the lowering has to know.
SWIFTUIWEB_MODULE_ALIASES=1 \
SWIFTUIWEB_PACKAGE_ROOT="$work/MotionDemo" \
SWIFTUIWEB_PRODUCT=MotionDemo \
SWIFTUIWEB_BUNDLE_ROOT="$work/browser" \
BUILD_ONLY=1 \
CONFIGURATION="${CONFIGURATION:-release}" \
  "$swiftuiweb/Tools/run-browser-embedded.sh" MotionDemo

if [[ "${1:-}" == --test ]]; then
  exec bun "$web/demo/test-browser.mjs" "$work/browser/MotionDemo"
fi
exec bun "$swiftuiweb/Tools/bun-server.ts" "$work/browser/MotionDemo" "${PORT:-8080}"
