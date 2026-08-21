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

# Record where this clone lives, so the app's "Atualizar" button knows what
# to `git pull` — it has no other way to find its own source directory.
SUPPORT="$HOME/Library/Application Support/ClipBar"
mkdir -p "$SUPPORT"
echo "$ROOT" > "$SUPPORT/source-path.txt"

echo "→ instalado em $TARGET"
open "$TARGET"
