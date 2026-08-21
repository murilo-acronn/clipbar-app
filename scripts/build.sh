#!/usr/bin/env bash
# Builds ClipBar.app without Xcode: SwiftPM compiles the binary, we assemble
# the bundle by hand and sign it with the stable local identity when available.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="ClipBar"
CONFIG="${CONFIG:-debug}"
APP="$ROOT/build/$APP_NAME.app"

# -j 3: this is a 16GB machine and SwiftPM would otherwise fan out to all
# 10 cores, spiking several GB and pushing the system into memory pressure.
JOBS="${JOBS:-3}"
swift build -c "$CONFIG" -j "$JOBS"
BIN="$(swift build -c "$CONFIG" -j "$JOBS" --show-bin-path)/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
[ -d "$ROOT/Resources/Sounds" ] && cp -R "$ROOT/Resources/Sounds" "$APP/Contents/Resources/"

# signing.sh falls back to ad-hoc only when the local identity is unavailable.
. "$ROOT/scripts/signing.sh"
# No 2>/dev/null here: a signing failure has to be loud, not silent.
codesign --force --sign "$SIGN_ID" "$APP"

echo "→ $APP"
