#!/usr/bin/env bash
# Builds and installs into /Applications, then relaunches.
#
# Living in /Applications matters for more than tidiness: macOS keys the
# Accessibility grant to the app's path as well as its signature, and a path
# under build/ would break every time the folder moved.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClipBar"
TARGET="/Applications/$APP_NAME.app"

"$ROOT/scripts/build.sh"

pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 1

rm -rf "$TARGET"
cp -R "$ROOT/build/$APP_NAME.app" "$TARGET"
. "$ROOT/scripts/signing.sh"
codesign --force --sign "$SIGN_ID" "$TARGET"

echo "→ instalado em $TARGET"
open "$TARGET"
