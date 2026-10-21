#!/usr/bin/env bash
# ===========================================================================
#  extract-icon.sh -- use the game's own icon for the launcher
#
#  A Windows .exe carries its icons inside it as resources. Hello Neighbor's
#  executables hold the real artwork tinyBuild shipped, which is a far better
#  launcher icon than anything we can draw. This pulls the largest one out and
#  installs it into the ChromeOS launcher.
#
#  Safe to re-run. If anything is missing it leaves the existing icon alone
#  and exits 0, so install.sh can call it unconditionally.
#
#  Usage:  ./tools/extract-icon.sh [--game-dir DIR] [--restore]
#            --game-dir DIR   where the game lives
#                             (default ~/.local/share/hello-neighbor/game)
#            --restore        put the bundled fallback icon back
# ===========================================================================
set -Eeuo pipefail

APP_ID="hello-neighbor"
APP_HOME="$HOME/.local/share/$APP_ID"
GAME_DIR="$APP_HOME/game"
ICON_BASE="$HOME/.local/share/icons/hicolor"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESTORE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --game-dir) shift; GAME_DIR="${1:-$GAME_DIR}" ;;
    --restore)  RESTORE=1 ;;
    -h|--help)  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ -t 1 ]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
else B=""; G=""; Y=""; C=""; N=""; fi
hdr()  { printf '\n%s==> %s%s\n' "$B$C" "$1" "$N"; }
ok()   { printf '    %s*%s %s\n' "$G" "$N" "$1"; }
warn() { printf '    %s!%s %s\n' "$Y" "$N" "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# convert(1) is ImageMagick 6, magick(1) is 7. Support both.
if have magick; then IM="magick"; elif have convert; then IM="convert"; else IM=""; fi

install_png() {  # install_png <source.png>
  local src="$1" sz
  [ -n "$IM" ] || { warn "ImageMagick not installed -- cannot resize"; return 1; }
  for sz in 16 24 32 48 64 128 256 512; do
    mkdir -p "$ICON_BASE/${sz}x${sz}/apps"
    $IM "$src" -background none -resize "${sz}x${sz}" -gravity center \
        -extent "${sz}x${sz}" "$ICON_BASE/${sz}x${sz}/apps/$APP_ID.png" 2>/dev/null || return 1
  done
  mkdir -p "$APP_HOME"
  cp -f "$src" "$APP_HOME/icon.png"
  have gtk-update-icon-cache && gtk-update-icon-cache -f -t "$ICON_BASE" >/dev/null 2>&1 || true
  return 0
}

if [ "$RESTORE" = "1" ]; then
  hdr "Restoring the bundled icon"
  if [ -f "$SRC_DIR/launcher/$APP_ID.png" ] && install_png "$SRC_DIR/launcher/$APP_ID.png"; then
    ok "bundled icon reinstalled"
  else
    warn "could not restore -- $SRC_DIR/launcher/$APP_ID.png missing?"
  fi
  exit 0
fi

hdr "Reading the icon out of the game's .exe"

if [ ! -d "$GAME_DIR" ]; then
  warn "game folder not found: $GAME_DIR"
  warn "keeping the current icon"
  exit 0
fi

# icoutils gives us wrestool (pull resources out of a PE binary) and icotool
# (convert .ico to .png). Both live in the same Debian package.
if ! have wrestool || ! have icotool; then
  echo "    installing icoutils (needed to read Windows icon resources)..."
  if sudo apt-get install -y -qq icoutils >/dev/null 2>&1; then
    ok "icoutils installed"
  else
    warn "could not install icoutils -- keeping the current icon"
    warn "try manually:  sudo apt install icoutils"
    exit 0
  fi
fi

# The small launcher .exe at the game root normally carries the nicest icon;
# the shipping binary in Binaries/Win64 is the fallback.
mapfile -t CANDIDATES < <(
  find -L "$GAME_DIR" -maxdepth 1 -iname '*.exe' -type f 2>/dev/null
  find -L "$GAME_DIR" -ipath '*/Binaries/Win64/*' -iname '*.exe' -type f 2>/dev/null
)

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  warn "no .exe found under $GAME_DIR -- keeping the current icon"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FOUND=0
for exe in "${CANDIDATES[@]}"; do
  base="$(basename "$exe")"
  # resource type 14 is RT_GROUP_ICON
  if wrestool -x -t 14 -o "$WORK" "$exe" >/dev/null 2>&1; then
    n=$(find "$WORK" -maxdepth 1 -name '*.ico' | wc -l)
    if [ "$n" -gt 0 ]; then
      ok "found icon resources in $base"
      FOUND=1
      break
    fi
  fi
  warn "no icon resource in $base"
done

if [ "$FOUND" = "0" ]; then
  warn "none of the executables carry an icon -- keeping the current icon"
  exit 0
fi

mkdir -p "$WORK/png"
for ico in "$WORK"/*.ico; do
  icotool -x -o "$WORK/png" "$ico" >/dev/null 2>&1 || true
done

# Pick the biggest image we extracted. icotool names files like
# foo_1_256x256x32.png, but measure them rather than trust the filename.
BEST=""; BEST_PX=0
shopt -s nullglob
for png in "$WORK/png"/*.png; do
  if [ -n "$IM" ]; then
    dims="$($IM identify -format '%w %h' "$png" 2>/dev/null || echo "0 0")"
  else
    dims="0 0"
  fi
  w="${dims% *}"; h="${dims#* }"
  [ -n "$w" ] && [ -n "$h" ] || continue
  px=$(( w * h ))
  if [ "$px" -gt "$BEST_PX" ]; then BEST_PX="$px"; BEST="$png"; fi
done
shopt -u nullglob

if [ -z "$BEST" ]; then
  warn "could not decode any icon image -- keeping the current icon"
  exit 0
fi

ok "largest icon: $($IM identify -format '%wx%h' "$BEST" 2>/dev/null) from the game binary"

if [ "$BEST_PX" -lt $((48 * 48)) ]; then
  warn "that icon is tiny and would look blurry -- keeping the current icon"
  warn "run with --restore if you want the bundled one back"
  exit 0
fi

if install_png "$BEST"; then
  ok "${B}the launcher now uses the game's own icon${N}"
  echo "    revert any time with:  ./tools/extract-icon.sh --restore"
else
  warn "install failed -- keeping the current icon"
fi
