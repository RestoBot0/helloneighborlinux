#!/usr/bin/env bash
# ===========================================================================
#  crash-trace.sh -- find out WHY the game died, not just that it died
#
#  The launcher normally runs Wine with its error output switched off, which
#  is fine until the game crashes: a missing DLL or an access violation then
#  leaves nothing behind but a truncated exit code. This runs the game once
#  with Wine's exception tracing on, then prints only the useful parts.
#
#  Background: Wine reports a Windows exit status through an 8-bit shell
#  exit code, so the famous 0xC0000005 (access violation -- the Windows
#  equivalent of a segfault) arrives as rc=5. rc=3 is our old winevulkan
#  assertion. This script reads the real status out of the log instead.
#
#  Usage:  ./tools/crash-trace.sh [--seconds N] [--quick]
#            --seconds N   how long to let the game run (default 90)
#            --quick       re-read the last run's log, do not relaunch
# ===========================================================================
set -uo pipefail

APP_ID="hello-neighbor"
APP_HOME="$HOME/.local/share/$APP_ID"
LAUNCH="$APP_HOME/bin/$APP_ID-launch"
LOG_DIR="$APP_HOME/logs"
OUT="$LOG_DIR/crash-trace.log"
MARKER="$LOG_DIR/.crash-trace-marker"
SECS=90
QUICK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) shift; SECS="${1:-90}" ;;
    --quick)   QUICK=1 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ -t 1 ]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
else B=""; G=""; Y=""; R=""; C=""; N=""; fi

[ -x "$LAUNCH" ] || { echo "Launcher not found at $LAUNCH -- run install.sh first." >&2; exit 1; }

section() { printf '\n%s===== %s =====%s\n' "$B$C" "$1" "$N"; }

if [ "$QUICK" = "0" ]; then
  printf '\n%sRunning the game with Wine exception tracing on, up to %ss.%s\n' "$B$C" "$SECS" "$N"
  printf 'It will be slower than usual and may still crash -- that is the point.\n'
  printf 'Nothing to click; it stops on its own.\n\n'

  "$LAUNCH" --kill >/dev/null 2>&1
  pkill -f 'HelloNeighbor-Win64-Shipping' >/dev/null 2>&1
  wineserver -k >/dev/null 2>&1
  sleep 1

  rm -f "$LOG_DIR"/launch-*.log 2>/dev/null
  # Drop a marker file the instant before launch. Anything under Saved/ that
  # is newer than this was written by the GAME, not by the installer -- which
  # has usually just rewritten every .ini itself and would otherwise look
  # exactly like game activity.
  touch "$MARKER"
  sleep 1
  start=$(date +%s)
  # +seh      -> exception records and the unhandled-exception backtrace
  # +loaddll  -> every DLL actually loaded, so a failed import is visible
  env HN_WINEDEBUG="+seh,+loaddll" HN_VK_WSI_SW=1 HN_GAME_LOG=1 \
      timeout -k 5 "$SECS" "$LAUNCH" >/dev/null 2>&1
  elapsed=$(( $(date +%s) - start ))

  "$LAUNCH" --kill >/dev/null 2>&1
  pkill -f 'HelloNeighbor-Win64-Shipping' >/dev/null 2>&1
  wineserver -k >/dev/null 2>&1
  sleep 1

  cat "$LOG_DIR"/launch-*.log > "$OUT" 2>/dev/null
  printf 'Ran for %ss. Trace saved to %s (%s).\n' \
    "$elapsed" "$OUT" "$(du -h "$OUT" 2>/dev/null | cut -f1)"
fi

[ -s "$OUT" ] || { echo "No trace to read. Run it without --quick first." >&2; exit 1; }

# --- 0. is the game even reading our config? --------------------------------
# Everything this project tunes lives in .ini files under the prefix. If the
# game writes to that folder it is definitely reading it; if it never touches
# it, every .ini setting we have applied has been ignored and we have been
# tuning a file nobody reads.
section "game config"
SAVED=""
for d in "$APP_HOME"/prefix/drive_c/users/*/AppData/Local/HelloNeighbor/Saved; do
  [ -d "$d" ] && { SAVED="$d"; break; }
done
if [ -z "$SAVED" ]; then
  printf '%sno Saved folder under the prefix -- configs were never deployed%s\n' "$R" "$N"
else
  CFG="$SAVED/Config/WindowsNoEditor"
  printf 'config dir: %s\n' "$CFG"
  if grep -q 'bEnabled=false' "$CFG/Engine.ini" 2>/dev/null; then
    printf '%sSteam subsystem is switched off in Engine.ini%s\n' "$G" "$N"
  else
    printf '%sEngine.ini does NOT carry the Steam switch-off -- reinstall%s\n' "$R" "$N"
  fi
  if [ -f "$MARKER" ]; then
    printf '\nfiles written by the game itself since it was launched:\n'
    touched="$(find "$SAVED" -type f -newer "$MARKER" 2>/dev/null | sed "s|$SAVED/||" | head -12)"
    if [ -n "$touched" ]; then
      printf '%s%s%s\n' "$G" "$touched" "$N"
      printf '%s-> the game IS using this folder, so our .ini files are live%s\n' "$G" "$N"
    else
      printf '%snone%s\n' "$Y" "$N"
      printf '%s-> the game wrote nothing here. Either it crashed before it got%s\n' "$Y" "$N"
      printf '%s   the chance, or it keeps its settings somewhere else entirely%s\n' "$Y" "$N"
      printf '%s   and every .ini we have tuned is being ignored.%s\n' "$Y" "$N"
    fi
  fi
  printf '\nwhole Saved tree:\n'
  find "$SAVED" -maxdepth 2 2>/dev/null | sed "s|$SAVED|Saved|" | head -15
fi

# --- 1. did a DLL fail to load? --------------------------------------------
section "missing or broken DLLs"
miss="$(grep -aE 'import_dll|is not a Win(32|64)|not found|Library .* not found|failed to load' "$OUT" 2>/dev/null \
        | grep -av 'loaddll' | sort -u | head -15)"
if [ -n "$miss" ]; then printf '%s%s%s\n' "$R" "$miss" "$N"
else printf '%snone -- every import resolved%s\n' "$G" "$N"; fi

# --- 2. did Wine hit a function it does not implement? ---------------------
section "unimplemented Wine functions called"
unimp="$(grep -aE 'unimplemented function|stub' "$OUT" 2>/dev/null | sort -u | head -10)"
if [ -n "$unimp" ]; then printf '%s%s%s\n' "$Y" "$unimp" "$N"
else printf '%snone%s\n' "$G" "$N"; fi

# --- 2b. did it try to reach Steam? -----------------------------------------
section "Steam"
st="$(grep -a 'S_API\|steamclient\|SteamAPI_Init' "$OUT" 2>/dev/null | sort -u | head -5)"
if [ -n "$st" ]; then
  printf '%s%s%s\n' "$R" "$st" "$N"
  printf '\nThis is a Steam build calling into Steam while Steam is not running.\n'
  printf 'It does not handle the failure and crashes a few seconds later.\n'
  printf 'Engine.ini should carry [OnlineSubsystemSteam] bEnabled=false.\n'
else
  printf '%sno Steam calls recorded%s\n' "$G" "$N"
fi

# --- 3. the exception itself ------------------------------------------------
# 0xe06d7363 is a normal C++ throw and 0x406d1388 is a thread-name marker;
# both are routine and would drown out the real one.
section "exceptions raised (routine C++ throws filtered out)"
exc="$(grep -a 'dispatch_exception\|Unhandled exception\|page fault' "$OUT" 2>/dev/null \
       | grep -av 'e06d7363\|406d1388' | tail -12)"
if [ -n "$exc" ]; then printf '%s%s%s\n' "$R" "$exc" "$N"
else printf '%snone recorded%s\n' "$G" "$N"; fi

# --- 4. which module was executing ------------------------------------------
section "backtrace / faulting module"
bt="$(grep -aA25 'Unhandled exception\|wine: Unhandled' "$OUT" 2>/dev/null | tail -26)"
if [ -n "$bt" ]; then printf '%s\n' "$bt"
else printf '%snone -- the process was not killed by an unhandled exception%s\n' "$Y" "$N"; fi

# --- 5. how it ended --------------------------------------------------------
section "how it ended"
rc="$(grep -ao 'game exited rc=[0-9]*' "$OUT" 2>/dev/null | tail -1 | cut -d= -f2)"
case "${rc:-}" in
  "")  printf 'no exit code recorded\n' ;;
  0)   printf '%src=0 -- clean exit%s\n' "$G" "$N" ;;
  3)   printf '%src=3 -- winevulkan assertion (the old crash)%s\n' "$R" "$N" ;;
  5)   printf '%src=5 -- 0xC0000005 ACCESS VIOLATION (crash inside the game)%s\n' "$R" "$N" ;;
  11)  printf '%src=11 -- 0xC000000B / segmentation fault%s\n' "$R" "$N" ;;
  53)  printf '%src=53 -- 0xC0000135 a DLL was not found%s\n' "$R" "$N" ;;
  *)   printf '%src=%s%s\n' "$Y" "$rc" "$N" ;;
esac

section "last 20 lines before it died"
grep -av '^trace:\|^[0-9a-f]*:trace:' "$OUT" 2>/dev/null | tail -20

printf '\n%sPaste everything from "missing or broken DLLs" downwards back to me.%s\n' "$B" "$N"
printf 'The full trace stays at %s if we need more.\n\n' "$OUT"
