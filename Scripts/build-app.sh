#!/bin/zsh

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH_PATH="${SCRATCH_PATH:-/tmp/antler-build}"
BUILD_CONFIG="${BUILD_CONFIG:-debug}"
APP_DIR="${APP_DIR:-$ROOT_DIR/dist/Antler.app}"
ICON_SOURCE="${ICON_SOURCE:-$ROOT_DIR/deer.png}"
swift build --scratch-path "$SCRATCH_PATH" --configuration "$BUILD_CONFIG"
BIN_DIR=$(swift build --scratch-path "$SCRATCH_PATH" --configuration "$BUILD_CONFIG" --show-bin-path)
EXECUTABLE="$BIN_DIR/Antler"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/antler-icon.XXXXXX")
ICONSET_DIR="$TEMP_DIR/AppIcon.iconset"

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "Expected executable at $EXECUTABLE" >&2
  exit 1
fi

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Expected icon source at $ICON_SOURCE" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
mkdir -p "$ICONSET_DIR"

sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
cp "$ICON_SOURCE" "$ICONSET_DIR/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/Antler"
codesign --force --sign - --identifier "com.jack.antler" "$APP_DIR"

echo "Built app bundle at $APP_DIR"
