#!/usr/bin/env bash
set -euo pipefail

APP_NAME="YouTube Real Fullscreen Bridge.app"
LABEL="local.codex.youtube-real-fullscreen"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/$APP_NAME" ]]; then
  SOURCE_APP="$SCRIPT_DIR/$APP_NAME"
else
  SOURCE_APP="$SCRIPT_DIR/dist/$APP_NAME"
fi
INSTALL_DIR="$HOME/Applications"
TARGET_APP="$INSTALL_DIR/$APP_NAME"
TARGET_BINARY="$TARGET_APP/Contents/MacOS/YouTubeRealFullscreenBridge"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT="$LAUNCH_AGENT_DIR/$LABEL.plist"
TEMP_PLIST="$(mktemp -t youtube-real-fullscreen.XXXXXX)"

cleanup() {
  rm -f "$TEMP_PLIST"
}
trap cleanup EXIT

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing $APP_NAME next to this installer or in dist/." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR" "$LAUNCH_AGENT_DIR"
/usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"

plutil -create xml1 "$TEMP_PLIST"
plutil -insert Label -string "$LABEL" "$TEMP_PLIST"
plutil -insert ProgramArguments -json "[\"$TARGET_BINARY\"]" "$TEMP_PLIST"
plutil -insert RunAtLoad -bool true "$TEMP_PLIST"
plutil -insert KeepAlive -bool true "$TEMP_PLIST"
plutil -insert ProcessType -string Interactive "$TEMP_PLIST"
mv "$TEMP_PLIST" "$LAUNCH_AGENT"

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT"

echo
echo "Installed $APP_NAME."
echo "On first use, allow it in System Settings > Privacy & Security > Accessibility."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
