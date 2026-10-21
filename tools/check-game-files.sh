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

# --- the content paks -------------------------------------------------------
# A cooked UE4 game keeps essentially everything in Content/Paks. If that is
# missing or small, nothing else matters.
section "content paks"
mapfile -t PAKS < <(find -L "$GAME_DIR" -type f -iname '*.pak' -printf '%s %p\n' 2>/dev/null | sort -rn)
if [ "${#PAKS[@]}" -eq 0 ]; then
  printf '%sNO .pak FILES AT ALL.%s\n' "$R" "$N"
  printf 'A cooked Unreal game keeps its content in Content/Paks/*.pak.\n'
  printf 'Without them the engine starts, shows the logo, then dies as soon\n'
  printf 'as it tries to load a level -- which is the symptom we have.\n'
  note_problem
else
  total=0
  for row in "${PAKS[@]}"; do
    sz="${row%% *}"; path="${row#* }"
    total=$((total + sz))
    printf '  %10s  %s\n' "$(human "$sz")" "${path#"$GAME_DIR"/}"
  done
  printf '  %s-------------%s\n' "$B" "$N"
  printf '  %10s  total in %s pak file(s)\n' "$(human "$total")" "${#PAKS[@]}"
  if [ "$total" -lt 1000000000 ]; then
    printf '\n%sThat is under 1 GB, which is too small for this game.%s\n' "$R" "$N"
    note_problem
  else
    printf '\n%sPak size looks plausible.%s\n' "$G" "$N"
  fi
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
check_one "Content/Paks folder"      -type d -ipath '*Content/Paks'
check_one "Engine folder"            -type d -iname 'Engine' -maxdepth 2
check_one "Engine/Content"           -type d -ipath '*Engine/Content'
check_one "game AssetRegistry"       -type f -iname 'AssetRegistry.bin'
check_one "global shader cache"      -type f -iname 'GlobalShaderCache*.bin'

# --- what the tree actually looks like -------------------------------------
section "layout"
find -L "$GAME_DIR" -maxdepth 3 -type d 2>/dev/null \
  | sed "s|$GAME_DIR|.|" | sort | head -25

section "largest files"
find -L "$GAME_DIR" -type f -printf '%s %p\n' 2>/dev/null | sort -rn | head -8 \
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
