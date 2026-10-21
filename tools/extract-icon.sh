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
#  Usage:  ./tools/extract-icon.sh [--game-dir DIR] [--restore] [--verbose]
#            --game-dir DIR   where the game lives
#                             (default ~/.local/share/hello-neighbor/game)
#            --restore        put the bundled fallback icon back
#            --verbose        show every step (for when it does not work)
# ===========================================================================
set -Eeuo pipefail

APP_ID="hello-neighbor"
APP_HOME="$HOME/.local/share/$APP_ID"
GAME_DIR="$APP_HOME/game"
ICON_BASE="$HOME/.local/share/icons/hicolor"
PIXMAPS="$HOME/.local/share/pixmaps"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESTORE=0
VERBOSE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --game-dir) shift; GAME_DIR="${1:-$GAME_DIR}" ;;
    --restore)  RESTORE=1 ;;
    --verbose|-v) VERBOSE=1 ;;
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
dbg()  { [ "$VERBOSE" = "1" ] && printf '      %s\n' "$1" || true; }
have() { command -v "$1" >/dev/null 2>&1; }

# convert(1) is ImageMagick 6, magick(1) is 7. Either is fine; neither is
# required for *finding* the best icon, only for resizing it.
pick_im() { if have magick; then IM="magick"; elif have convert; then IM="convert"; else IM=""; fi; }
pick_im

# --- measure a PNG without needing ImageMagick ------------------------------
# A PNG's width and height are two big-endian 32-bit ints at offset 16 in the
# IHDR chunk, which is always first. python3 is part of a base Debian install,
# so this works even on a container with no image tooling at all.
png_dims() {
  python3 - "$1" <<'PYEOF' 2>/dev/null || echo "0 0"
import struct, sys
try:
    with open(sys.argv[1], 'rb') as f:
        head = f.read(24)
    if head[:8] == b'\x89PNG\r\n\x1a\n':
        w, h = struct.unpack('>II', head[16:24])
        print(w, h)
    else:
        print(0, 0)
except Exception:
    print(0, 0)
PYEOF
}

install_png() {  # install_png <source.png>
  local src="$1" sz d native
  native="$(png_dims "$src")"; native="${native% *}"
  mkdir -p "$PIXMAPS" "$APP_HOME"
  for sz in 16 24 32 48 64 128 256 512; do
    d="$ICON_BASE/${sz}x${sz}/apps"; mkdir -p "$d"
    if [ -n "$IM" ]; then
      $IM "$src" -background none -resize "${sz}x${sz}" -gravity center \
          -extent "${sz}x${sz}" "$d/$APP_ID.png" 2>/dev/null || cp -f "$src" "$d/$APP_ID.png"
    else
      cp -f "$src" "$d/$APP_ID.png"
    fi
  done
  cp -f "$src" "$APP_HOME/icon.png"
  cp -f "$src" "$PIXMAPS/$APP_ID.png"
  have gtk-update-icon-cache && gtk-update-icon-cache -f -t "$ICON_BASE" >/dev/null 2>&1 || true
  [ -n "$IM" ] || warn "ImageMagick missing: installed the ${native}px icon unscaled at every size"
  return 0
}

if [ "$RESTORE" = "1" ]; then
  hdr "Restoring the bundled icon"
  if [ -f "$SRC_DIR/launcher/$APP_ID.png" ]; then
    install_png "$SRC_DIR/launcher/$APP_ID.png" && ok "bundled icon reinstalled"
  else
    warn "could not restore -- $SRC_DIR/launcher/$APP_ID.png missing?"
  fi
  exit 0
fi

hdr "Reading the icon out of the game's .exe"

if [ ! -d "$GAME_DIR" ]; then
  warn "game folder not found: $GAME_DIR -- keeping the current icon"
  exit 0
fi

# icoutils gives us wrestool (pull resources out of a PE binary) and icotool
# (convert .ico to .png). ImageMagick is optional but makes the result sharp.
if ! have wrestool || ! have icotool; then
  echo "    installing icoutils (needed to read Windows icon resources)..."
  sudo apt-get install -y -qq icoutils >/dev/null 2>&1 \
    && ok "icoutils installed" \
    || { warn "could not install icoutils -- keeping the current icon"
         warn "try manually:  sudo apt install icoutils"; exit 0; }
fi
if [ -z "$IM" ]; then
  echo "    installing imagemagick (so the icon is resized cleanly)..."
  sudo apt-get install -y -qq imagemagick >/dev/null 2>&1 && pick_im
  [ -n "$IM" ] && ok "imagemagick installed" || warn "no imagemagick; continuing without resizing"
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
mkdir -p "$WORK/ico" "$WORK/png"

BEST=""; BEST_PX=0

consider() {  # consider <png>  -- keep it if it is the biggest so far
  local f="$1" dims w h px
  dims="$(png_dims "$f")"; w="${dims% *}"; h="${dims#* }"
  [ -n "$w" ] && [ -n "$h" ] || return 0
  px=$(( w * h ))
  dbg "candidate $(basename "$f") -> ${w}x${h}"
  if [ "$px" -gt "$BEST_PX" ]; then BEST_PX="$px"; BEST="$f"; fi
}

for exe in "${CANDIDATES[@]}"; do
  base="$(basename "$exe")"
  rm -rf "${WORK:?}/ico"; mkdir -p "$WORK/ico"
  # resource type 14 is RT_GROUP_ICON
  wrestool -x -t 14 -o "$WORK/ico" "$exe" >/dev/null 2>&1 || true
  # wrestool names resources like "Foo.exe_14_101_1033" with no extension.
  # Both icotool and ImageMagick identify formats by suffix, so give them one.
  while IFS= read -r f; do
    case "$f" in *.ico) ;; *) mv -f "$f" "$f.ico" ;; esac
  done < <(find "$WORK/ico" -type f)
  n_ico=$(find "$WORK/ico" -type f | wc -l)
  dbg "$base: $n_ico icon resource(s)"
  [ "$n_ico" -gt 0 ] || { dbg "$base: no icon resource"; continue; }
  ok "found icon resources in $base"

  before=$(find "$WORK/png" -name '*.png' | wc -l)
  # wrestool does not always append .ico, so feed it everything it wrote.
  while IFS= read -r ico; do
    icotool -x -o "$WORK/png" "$ico" >/dev/null 2>&1 || true
  done < <(find "$WORK/ico" -type f)
  after=$(find "$WORK/png" -name '*.png' | wc -l)
  dbg "icotool produced $(( after - before )) png(s)"

  # Vista-era .ico files embed PNGs that some icotool builds skip. If icotool
  # gave us nothing, ImageMagick can usually read the .ico directly.
  if [ "$after" -eq "$before" ] && [ -n "$IM" ]; then
    dbg "icotool produced nothing; trying ImageMagick on the .ico"
    i=0
    while IFS= read -r ico; do
      i=$((i+1))
      $IM "ico:$ico" "$WORK/png/im_${i}_%d.png" 2>/dev/null \
        || $IM "$ico" "$WORK/png/im_${i}_%d.png" 2>/dev/null || true
    done < <(find "$WORK/ico" -type f)
    dbg "imagemagick produced $(( $(find "$WORK/png" -name '*.png' | wc -l) - before )) png(s)"
  fi
done

shopt -s nullglob
for png in "$WORK/png"/*.png; do consider "$png"; done
shopt -u nullglob

if [ -z "$BEST" ]; then
  warn "found icon resources but could not decode any image"
  warn "keeping the current icon. Re-run with --verbose to see why."
  exit 0
fi

BEST_W="$(png_dims "$BEST")"; BEST_W="${BEST_W% *}"
ok "largest icon in the game binary: ${BEST_W}x${BEST_W}"

if [ "$BEST_PX" -lt $((48 * 48)) ]; then
  warn "that is too small to look good -- keeping the current icon"
  exit 0
fi

install_png "$BEST"
ok "${B}the launcher now uses the game's own icon${N}"
echo "    revert any time with:  ./tools/extract-icon.sh --restore"
