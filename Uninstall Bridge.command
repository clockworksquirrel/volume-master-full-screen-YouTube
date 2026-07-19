#!/usr/bin/env bash
set -euo pipefail

APP_NAME="YouTube Real Fullscreen Bridge.app"
LABEL="local.codex.youtube-real-fullscreen"
TARGET_APP="$HOME/Applications/$APP_NAME"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
TRASH_DIR="$HOME/.Trash"
STAMP="$(date +%Y%m%d-%H%M%S)"

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
mkdir -p "$TRASH_DIR"

if [[ -e "$TARGET_APP" ]]; then
  mv "$TARGET_APP" "$TRASH_DIR/YouTube Real Fullscreen Bridge-$STAMP.app"
fi

if [[ -e "$LAUNCH_AGENT" ]]; then
  mv "$LAUNCH_AGENT" "$TRASH_DIR/$LABEL-$STAMP.plist"
fi

echo "The bridge and launch agent were moved to Trash and can be recovered there."
