#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="YouTube Real Fullscreen Bridge"
PROCESS_NAME="YouTubeRealFullscreenBridge"
BUNDLE_ID="local.codex.youtube-real-fullscreen"
APP_VERSION="1.1.0"
BUNDLE_VERSION="2"
MIN_SYSTEM_VERSION="12.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$PROCESS_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true

swift build --package-path "$ROOT_DIR"
BUILD_BINARY="$(swift build --package-path "$ROOT_DIR" --show-bin-path)/$PROCESS_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

plutil -create xml1 "$INFO_PLIST"
plutil -insert CFBundleExecutable -string "$PROCESS_NAME" "$INFO_PLIST"
plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$INFO_PLIST"
plutil -insert CFBundleName -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundlePackageType -string APPL "$INFO_PLIST"
plutil -insert CFBundleShortVersionString -string "$APP_VERSION" "$INFO_PLIST"
plutil -insert CFBundleVersion -string "$BUNDLE_VERSION" "$INFO_PLIST"
plutil -insert LSMinimumSystemVersion -string "$MIN_SYSTEM_VERSION" "$INFO_PLIST"
plutil -insert LSUIElement -bool true "$INFO_PLIST"
plutil -insert NSPrincipalClass -string NSApplication "$INFO_PLIST"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"

open_app() {
  /usr/bin/open -gj "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    curl --fail --silent --show-error --retry 10 --retry-connrefused --retry-delay 0 \
      "http://127.0.0.1:38471/health" >/dev/null
    pgrep -f "$APP_BINARY" >/dev/null
    ;;
  --probe|probe)
    "$APP_BINARY" --probe
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--probe]" >&2
    exit 2
    ;;
esac
