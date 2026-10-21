#!/usr/bin/env bash
# ===========================================================================
#  check-game-files.sh -- is the copy of the game actually complete?
#
#  Every crash chased so far has been treated as an environment problem. It
#  is worth ruling out the other possibility: that the files themselves are
#  incomplete. The game was moved between machines as a zip, and a UE4 title
#  will start, show its logo, and only then die if the content it needs is
#  missing or truncated -- which is exactly the symptom here.
#
#  This reads only; it changes nothing.
#
#  Usage:  ./tools/check-game-files.sh [--game-dir DIR]
# ===========================================================================
set -uo pipefail

APP_ID="hello-neighbor"
APP_HOME="$HOME/.local/share/$APP_ID"
GAME_DIR="$APP_HOME/game"

while [ $# -gt 0 ]; do
  case "$1" in
    --game-dir) shift; GAME_DIR="${1:-}" ;;
    -h|--help)  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ -t 1 ]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
else B=""; G=""; Y=""; R=""; C=""; N=""; fi

[ -d "$GAME_DIR" ] || { echo "No game folder at $GAME_DIR" >&2; exit 1; }

section() { printf '\n%s===== %s =====%s\n' "$B$C" "$1" "$N"; }
human()   { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0} bytes"; }

PROBLEMS=0
note_problem() { PROBLEMS=$((PROBLEMS+1)); }

section "where the game is"
printf '%s\n' "$GAME_DIR"
printf 'total size: %s in %s files\n' \
  "$(du -shL "$GAME_DIR" 2>/dev/null | cut -f1)" \
  "$(find -L "$GAME_DIR" -type f 2>/dev/null | wc -l)"

# --- what kind of build is this? -------------------------------------------
# Unreal packages a game in one of three shapes and a Shipping .exe can only
# load the first two:
#
#   cooked + paked : everything inside Content/Paks/*.pak
#   cooked, loose  : .uasset files on disk, each paired with a .uexp
#   uncooked       : editor project content, .uasset with NO .uexp
#
# The .uexp pairing is the reliable tell. Cooking splits every asset into a
# header (.uasset) and its exports (.uexp), with bulk data in .ubulk. Editor
# assets are a single self-contained .uasset. So "lots of .uasset and no
# .uexp" means this is raw project content that a Shipping build cannot
# load -- it will start, show its logo, and die when it reaches for a map.
section "what kind of build this is"
count_ext() { find -L "$GAME_DIR" -type f -iname "*.$1" 2>/dev/null | wc -l; }
N_PAK="$(count_ext pak)"; N_UASSET="$(count_ext uasset)"
N_UEXP="$(count_ext uexp)"; N_UBULK="$(count_ext ubulk)"
N_UMAP="$(count_ext umap)"; N_UPROJECT="$(count_ext uproject)"
printf '  %-28s %s\n' ".pak (packaged content)"  "$N_PAK"
printf '  %-28s %s\n' ".uasset (asset headers)"  "$N_UASSET"
printf '  %-28s %s\n' ".uexp (cooked exports)"   "$N_UEXP"
printf '  %-28s %s\n' ".ubulk (cooked bulk data)" "$N_UBULK"
printf '  %-28s %s\n' ".umap (levels)"           "$N_UMAP"
printf '  %-28s %s\n' ".uproject (editor project)" "$N_UPROJECT"

GAME_PAKS="$(find -L "$GAME_DIR" -type f -iname '*.pak' -ipath '*Content/Paks*' 2>/dev/null | wc -l)"
printf '\n'
if [ "$GAME_PAKS" -gt 0 ]; then
  printf '%sCooked and packaged.%s Content is in Content/Paks, which is what a\n' "$G" "$N"
  printf 'retail build normally looks like.\n'
elif [ "$N_UEXP" -gt 0 ]; then
  printf '%sCooked, stored as loose files.%s The assets are cooked (%s .uexp\n' "$G" "$N" "$N_UEXP"
  printf 'files) and simply were not packed. A Shipping build loads this.\n'
elif [ "$N_UASSET" -gt 0 ]; then
  # No .uexp is NOT proof of uncooked content. The .uasset/.uexp split comes
  # from the Event Driven Loader; cook with it off and you get cooked
  # single-file .uasset instead, as shipped UE4 titles have done. So fall
  # back to markers only a cook produces: AssetRegistry.bin and the global
  # shader cache. Hello Neighbor in particular ships loose with no
  # Content/Paks -- its own modding guides tell people to create that folder.
  COOKMARK=0
  find -L "$GAME_DIR" -type f -iname 'AssetRegistry.bin'      -print -quit 2>/dev/null | grep -q . && COOKMARK=$((COOKMARK+1))
  find -L "$GAME_DIR" -type f -iname 'GlobalShaderCache*.bin' -print -quit 2>/dev/null | grep -q . && COOKMARK=$((COOKMARK+1))
  if [ "$COOKMARK" -ge 2 ]; then
    printf '%sCooked, loose, single-file assets.%s %s .uasset files and no .uexp,\n' "$G" "$N" "$N_UASSET"
    printf 'but AssetRegistry.bin and the global shader cache are both present\n'
    printf 'and those are produced by cooking. The .uasset/.uexp split only\n'
    printf 'happens with the Event Driven Loader on at cook time.\n'
    printf '\n%sThis is a normal Hello Neighbor install. Nothing to fix here.%s\n' "$G" "$N"
  else
    printf '%sPossibly uncooked editor content.%s %s .uasset files, no .uexp, and\n' "$R" "$N" "$N_UASSET"
    printf 'neither AssetRegistry.bin nor a global shader cache, both of which\n'
    printf 'cooking produces. A Shipping build cannot load raw editor content.\n'
    note_problem
  fi
else
  printf '%sNo Unreal content found at all.%s\n' "$R" "$N"
  note_problem
fi

# Editor-only engine content is another strong hint that this folder is a
# project tree rather than a packaged game.
EDITORDIRS="$(find -L "$GAME_DIR/Engine/Content" -maxdepth 1 -type d -iname 'Editor*' 2>/dev/null | wc -l)"
if [ "$EDITORDIRS" -gt 0 ]; then
  printf '\n%sNote: Engine/Content holds %s Editor* folders.%s Cooking strips editor\n' \
    "$Y" "$EDITORDIRS" "$N"
  printf 'content only when "Exclude editor content when cooking" is enabled,\n'
  printf 'which many 2017-era titles left off. On its own this is not a fault.\n'
fi

# --- truncation -------------------------------------------------------------
# A transfer that ran out of space or was interrupted leaves empty files
# behind rather than missing ones.
section "empty or suspiciously small files"
empties="$(find -L "$GAME_DIR" -type f -size 0 2>/dev/null | head -10)"
if [ -n "$empties" ]; then
  printf '%s%s%s\n' "$R" "$empties" "$N"
  printf '%s(%s empty files in total)%s\n' "$R" \
    "$(find -L "$GAME_DIR" -type f -size 0 2>/dev/null | wc -l)" "$N"
  note_problem
else
  printf '%snone%s\n' "$G" "$N"
fi

# --- the pieces that must exist --------------------------------------------
section "required pieces"
check_one() { # check_one <description> <find-args...>
  local desc="$1"; shift
  local hit
  hit="$(find -L "$GAME_DIR" "$@" 2>/dev/null | head -1)"
  if [ -n "$hit" ]; then
    printf '  %s[ok]%s   %-34s %s\n' "$G" "$N" "$desc" \
      "$(du -shL "$hit" 2>/dev/null | cut -f1)"
  else
    printf '  %s[MISSING]%s %s\n' "$R" "$N" "$desc"
    note_problem
  fi
}
check_one "shipping executable"      -type f -iname 'HelloNeighbor-Win64-Shipping.exe'
check_one "game Content folder"      -type d -ipath '*HelloNeighbor/Content'
check_one "Engine folder"            -type d -iname 'Engine' -maxdepth 2
check_one "Engine/Content"           -type d -ipath '*Engine/Content'
check_one "game AssetRegistry"       -type f -iname 'AssetRegistry.bin'
check_one "global shader cache"      -type f -iname 'GlobalShaderCache*.bin'

# --- what the tree actually looks like -------------------------------------
section "layout"
find -L "$GAME_DIR" -maxdepth 3 -type d 2>/dev/null \
  | sed "s|$GAME_DIR|.|" | sort | head -25

section "largest files"
find -L "$GAME_DIR" -type f -printf '%s %p\n' 2>/dev/null | sort -rn 2>/dev/null | head -8 \
  | while read -r sz path; do printf '  %10s  %s\n' "$(human "$sz")" "${path#"$GAME_DIR"/}"; done

# --- verdict ----------------------------------------------------------------
section "verdict"
if [ "$PROBLEMS" -eq 0 ]; then
  printf '%sThe install looks complete. The crash is an environment problem,%s\n' "$G" "$N"
  printf '%snot a missing-files problem.%s\n' "$G" "$N"
else
  printf '%s%s problem(s) found above.%s\n' "$R" "$PROBLEMS" "$N"
  printf 'If content is missing or truncated, no amount of Wine or driver\n'
  printf 'tuning will help -- the copy of the game needs replacing.\n'
fi
printf '\n'
