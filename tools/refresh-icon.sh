#!/usr/bin/env bash
# ===========================================================================
#  refresh-icon.sh -- make ChromeOS notice that the app icon changed
#
#  ChromeOS does not read the icon out of your .desktop file whenever it
#  feels like it. Inside the container a daemon called garcon watches the
#  applications directories and reports the app list across to ChromeOS;
#  ChromeOS then asks garcon for each app's icon -- but only when an app
#  appears or disappears. Replacing the PNG, or editing the .desktop file in
#  place, is not a change it will ever look at. The old picture lives in a
#  cache on the ChromeOS side, outside the container, where nothing you run
#  in here can touch it.
#
#  So this does the one thing that does work: takes the launcher entry away,
#  waits for ChromeOS to notice the app is gone, and puts it back. It
#  returns as a "new" app, and new apps get their icon fetched.
#
#  Usage:  ./tools/refresh-icon.sh [--wait N] [--image FILE]
#            --wait N      seconds to stay "uninstalled" (default 25)
#            --image FILE  set a new icon from FILE first, then refresh
# ===========================================================================
set -Eeuo pipefail

APP_ID="hello-neighbor"
APP_HOME="$HOME/.local/share/$APP_ID"
DESKTOP_DIR="$HOME/.local/share/applications"
ICON_BASE="$HOME/.local/share/icons/hicolor"
PIXMAPS="$HOME/.local/share/pixmaps"
STASH="$APP_HOME/.icon-refresh"
WAIT=25
IMAGE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --wait)  shift; WAIT="${1:-25}" ;;
    --image) shift; IMAGE="${1:-}" ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
else B=""; G=""; Y=""; C=""; N=""; fi
hdr()  { printf '\n%s==> %s%s\n' "$B$C" "$1" "$N"; }
ok()   { printf '    %s*%s %s\n' "$G" "$N" "$1"; }
warn() { printf '    %s!%s %s\n' "$Y" "$N" "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -f "$DESKTOP_DIR/$APP_ID.desktop" ] || {
  warn "no launcher entry at $DESKTOP_DIR/$APP_ID.desktop -- run ./install.sh first"
  exit 1
}

# A previous run that was cut off half way leaves the entry in the stash.
if [ -d "$STASH" ]; then
  mv -f "$STASH"/*.desktop "$DESKTOP_DIR"/ 2>/dev/null || true
  rmdir "$STASH" 2>/dev/null || true
fi

# --- optionally install a new image first -----------------------------------
if [ -n "$IMAGE" ]; then
  hdr "Installing $IMAGE as the icon"
  [ -f "$IMAGE" ] || { warn "no such file: $IMAGE"; exit 1; }
  case "$IMAGE" in
    *.png|*.PNG) : ;;
    *) warn "ChromeOS only accepts PNG icons -- SVG and JPG are ignored" ;;
  esac
  if have magick; then IM="magick"; elif have convert; then IM="convert"; else IM=""; fi
  for sz in 16 24 32 48 64 128 256 512; do
    d="$ICON_BASE/${sz}x${sz}/apps"; mkdir -p "$d"
    if [ -n "$IM" ]; then
      "$IM" "$IMAGE" -resize "${sz}x${sz}" "$d/$APP_ID.png" 2>/dev/null \
        || cp -f "$IMAGE" "$d/$APP_ID.png"
    else
      cp -f "$IMAGE" "$d/$APP_ID.png"
    fi
  done
  mkdir -p "$PIXMAPS"
  cp -f "$IMAGE" "$PIXMAPS/$APP_ID.png"
  cp -f "$IMAGE" "$APP_HOME/icon.png" 2>/dev/null || true
  ok "icon written at 8 sizes"
fi

# --- give the icon a name derived from its own bytes -------------------------
# ChromeOS caches by icon name as well, and has been known to refuse to let go
# of a name it has already decided about. A content hash means a changed image
# always arrives under a name ChromeOS has never seen.
# The pixmaps copy is a plain cp of the source image. Resized icons are
# convert(1) output, which embeds a timestamp and so changes every run.
MASTER="$PIXMAPS/$APP_ID.png"
[ -f "$MASTER" ] || MASTER="$ICON_BASE/256x256/apps/$APP_ID.png"
ICON_NAME="$APP_ID"
if [ -f "$MASTER" ]; then
  SUM="$( { md5sum "$MASTER" 2>/dev/null || cksum "$MASTER"; } | cut -c1-8 )"
  if [ -n "$SUM" ]; then
    ICON_NAME="$APP_ID-$SUM"
    for sz in 16 24 32 48 64 128 256 512; do
      d="$ICON_BASE/${sz}x${sz}/apps"
      find "$d" -maxdepth 1 -name "$APP_ID-*.png" ! -name "$ICON_NAME.png" -delete 2>/dev/null || true
      if [ -f "$d/$APP_ID.png" ]; then cp -f "$d/$APP_ID.png" "$d/$ICON_NAME.png"; fi
    done
    cp -f "$PIXMAPS/$APP_ID.png" "$PIXMAPS/$ICON_NAME.png" 2>/dev/null || true
  fi
fi
for f in "$DESKTOP_DIR/$APP_ID.desktop" "$DESKTOP_DIR/$APP_ID-safe.desktop"; do
  [ -f "$f" ] || continue
  sed -i "s|^Icon=.*|Icon=$ICON_NAME|" "$f"
done
ok "icon name: $ICON_NAME"

# --- the part that actually works -------------------------------------------
hdr "Asking ChromeOS to forget the old icon"
mkdir -p "$STASH"
# Put the entry back even if this gets interrupted.
trap 'mv -f "$STASH"/*.desktop "$DESKTOP_DIR"/ 2>/dev/null || true; rmdir "$STASH" 2>/dev/null || true' EXIT INT TERM

mv -f "$DESKTOP_DIR/$APP_ID.desktop" "$STASH"/
if [ -f "$DESKTOP_DIR/$APP_ID-safe.desktop" ]; then
  mv -f "$DESKTOP_DIR/$APP_ID-safe.desktop" "$STASH"/
fi
# garcon re-scans when this file is touched -- Debian's apt hook uses it too.
sudo -n touch /usr/share/applications/.garcon_trigger 2>/dev/null || true
have update-desktop-database && update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true

printf '    waiting %ss for the app to disappear from the launcher' "$WAIT"
_left="$WAIT"
while [ "$_left" -gt 0 ]; do sleep 1; _left=$((_left-1)); printf '.'; done
printf '\n'

mv -f "$STASH"/*.desktop "$DESKTOP_DIR"/
rmdir "$STASH" 2>/dev/null || true
trap - EXIT INT TERM
sudo -n touch /usr/share/applications/.garcon_trigger 2>/dev/null || true
have update-desktop-database && update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
have gtk-update-icon-cache && gtk-update-icon-cache -f -t "$ICON_BASE" 2>/dev/null || true
ok "launcher entry restored"

cat <<EOF

  Give the launcher up to a minute to catch up, then press the Search key
  and type ${B}Hello${N}.

  Still the old picture?
    1. If it is pinned to the shelf: right-click it, ${B}Unpin${N}, then find it
       in the launcher and ${B}Pin to shelf${N} again. The pin keeps its own copy.
    2. Failing that, run this again with a longer wait:
         ${B}./tools/refresh-icon.sh --wait 90${N}
    3. ChromeOS sometimes only lets go after a restart. It is annoying and
       it is not something the container can force.
EOF
