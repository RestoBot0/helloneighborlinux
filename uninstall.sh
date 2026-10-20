#!/usr/bin/env bash
# ===========================================================================
#  Remove everything install.sh created.
#      ./uninstall.sh            keep the game files, remove the integration
#      ./uninstall.sh --all      remove the game and the Wine prefix too
# ===========================================================================
set -Eeuo pipefail

APP_ID="hello-neighbor"
APP_HOME="$HOME/.local/share/$APP_ID"
DESKTOP_DIR="$HOME/.local/share/applications"
ICON_BASE="$HOME/.local/share/icons/hicolor"

REMOVE_ALL=0
[ "${1:-}" = "--all" ] && REMOVE_ALL=1

echo "Stopping any running instance..."
"$APP_HOME/bin/hello-neighbor-launch" --kill >/dev/null 2>&1 || true

echo "Removing the shelf entry and icons..."
rm -f "$DESKTOP_DIR/$APP_ID.desktop"
for sz in 16 24 32 48 64 128 256 512; do
  rm -f "$ICON_BASE/${sz}x${sz}/apps/$APP_ID.png"
done
rm -f "$HOME/.local/share/pixmaps/$APP_ID.png"
command -v update-desktop-database >/dev/null && update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
command -v gtk-update-icon-cache  >/dev/null && gtk-update-icon-cache -f -t "$ICON_BASE" 2>/dev/null || true

if [ "$REMOVE_ALL" = "1" ]; then
  echo "Removing game files and Wine prefix ($(du -sh "$APP_HOME" 2>/dev/null | cut -f1))..."
  rm -rf "$APP_HOME"
  echo "Everything removed."
else
  rm -rf "$APP_HOME/bin"
  echo "Integration removed. Game files kept at: $APP_HOME/game"
  echo "Run with --all to delete those too."
fi
