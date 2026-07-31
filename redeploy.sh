#!/bin/bash
# Build TextLift, fully quit any running instance, install to /Applications,
# relaunch, and VERIFY the running binary is the one we just built (an
# already-running instance would otherwise just re-activate stale, making
# changes look like they did nothing).
set -euo pipefail

APP="TextLift"
PROJ_DIR="/Users/moshe/Apps/TextLift"
BUILD_DIR="$PROJ_DIR/build.noindex"
SRC="$BUILD_DIR/Build/Products/Release/$APP.app"
DEST="/Applications/$APP.app"
BIN_REL="Contents/MacOS/$APP"

cd "$PROJ_DIR"

echo "▸ Building…"
# Signed with the Developer ID cert, NOT ad-hoc. This matters: macOS ties the
# Screen Recording grant to the app's code identity, and an ad-hoc signature
# changes on every single rebuild — so the permission silently lapses and
# screencapture starts handing back blank, window-less images. A stable identity
# means the grant survives rebuilds.
xcodebuild -project "$APP.xcodeproj" -scheme "$APP" -configuration Release \
  -derivedDataPath "$BUILD_DIR" build \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=VWR39LZW5M \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
  2>&1 | tee /tmp/textlift-build.log | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
# Check the build actually succeeded — a stale binary from a previous run would
# otherwise sail past the existence check and get installed silently.
grep -q "BUILD SUCCEEDED" /tmp/textlift-build.log || { echo "✘ build failed — not installing"; exit 1; }
[ -x "$SRC/$BIN_REL" ] || { echo "✘ build produced no binary"; exit 1; }

echo "▸ Quitting running instance…"
osascript -e "tell application \"$APP\" to quit" 2>/dev/null || true
pkill -f "$DEST/$BIN_REL" 2>/dev/null || true
for _ in $(seq 1 50); do
  pgrep -f "$DEST/$BIN_REL" >/dev/null 2>&1 || break
  sleep 0.2
done
if pgrep -f "$DEST/$BIN_REL" >/dev/null 2>&1; then
  echo "  …force-killing"; pkill -9 -f "$DEST/$BIN_REL" 2>/dev/null || true; sleep 0.5
fi

echo "▸ Installing…"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
NEW_MTIME=$(stat -f %m "$DEST/$BIN_REL")

echo "▸ Launching…"
open "$DEST"

# Belt and braces: the build product lives in a .noindex directory so Spotlight
# and Launch Services ignore it, and it is explicitly unregistered here too. Two
# bundles with the same id show up as duplicate apps in file pickers and confuse
# notification/permission lookups.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$SRC" 2>/dev/null || true

echo "▸ Signature:"
codesign -dv "$DEST" 2>&1 | grep -E "^(Signature|TeamIdentifier)" | sed 's/^/  /'

echo "▸ Verifying fresh instance…"
for _ in $(seq 1 25); do
  PID=$(pgrep -f "$DEST/$BIN_REL" | head -1 || true)
  [ -n "${PID:-}" ] && break
  sleep 0.2
done
if [ -z "${PID:-}" ]; then echo "✘ did not launch"; exit 1; fi
echo "✔ $APP running (pid $PID), binary built $(date -r "$NEW_MTIME" '+%H:%M:%S')"
