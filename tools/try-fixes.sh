#!/usr/bin/env bash
# ===========================================================================
#  try-fixes.sh -- run the game under several graphics configurations and
#                  report which one gets furthest
#
#  Rather than changing one setting, relaunching, and reading a log each
#  time, this tries the plausible combinations back to back and prints a
#  table. Each attempt is given a time limit and then killed, so a Wine
#  error dialog cannot stall the run -- you do not need to click anything.
#
#  Nothing is left modified: dxvk.conf is restored at the end.
#
#  Usage:  ./tools/try-fixes.sh [--seconds N] [--only N]
#            --seconds N   how long to let each attempt run (default 45)
#            --only N      run just attempt number N
# ===========================================================================
set -uo pipefail

APP_ID="hello-neighbor"
APP_HOME="$HOME/.local/share/$APP_ID"
LAUNCH="$APP_HOME/bin/$APP_ID-launch"
CONF="$APP_HOME/dxvk.conf"
LOG_DIR="$APP_HOME/logs"
SECS=45
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) shift; SECS="${1:-45}" ;;
    --only)    shift; ONLY="${1:-}" ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ -t 1 ]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
else B=""; G=""; Y=""; R=""; C=""; N=""; fi

[ -x "$LAUNCH" ] || { echo "Launcher not found at $LAUNCH -- run install.sh first." >&2; exit 1; }

ICD_DIR=/usr/share/vulkan/icd.d
VIRTIO_ICD=""
for cand in "$ICD_DIR/virtio_icd.x86_64.json" "$ICD_DIR/virtio_icd.json"; do
  [ -e "$cand" ] && { VIRTIO_ICD="$cand"; break; }
done

# --- the attempts -----------------------------------------------------------
# Each row: label | defer surface creation | WSI software present | virtual
#                   desktop | force a single Vulkan driver
#
# The first two settings were added to work around Wine 8 bugs. Wine is now
# 11.x, so they are prime suspects for causing harm rather than helping:
# deferSurfaceCreation changes when the Vulkan surface is created, and the
# crash we are chasing happens while querying a surface.
ATTEMPTS=(
  "stock Wine 11 behaviour (no Wine 8 workarounds)|0|0|0|0"
  "software frame presentation only|0|1|0|0"
  "deferred surface creation only|1|0|0|0"
  "both Wine 8 workarounds (current setting)|1|1|0|0"
  "stock + single Vulkan driver|0|0|0|1"
  "stock + Wine virtual desktop|0|0|1|0"
)

# The failure signatures we know how to recognise, most specific first.
classify() { # classify <logfile>
  local f="$1"
  grep -q 'vkGetPhysicalDeviceSurfaceFormatsKHR' "$f" 2>/dev/null && { echo "winevulkan assert (surface formats)"; return; }
  grep -q 'loader_thunks.c'                      "$f" 2>/dev/null && { echo "winevulkan assert (other)";           return; }
  grep -q '887A0020'                             "$f" 2>/dev/null && { echo "Present() failed 887A0020";           return; }
  grep -q 'CreateSwapChain'                      "$f" 2>/dev/null && { echo "CreateSwapChain failed";              return; }
  grep -q 'GL_RGBA8_SNORM'                       "$f" 2>/dev/null && { echo "WineD3D path (no Vulkan)";            return; }
  grep -qi 'No adapters found'                   "$f" 2>/dev/null && { echo "DXVK found no adapter";               return; }
  grep -qi 'LowLevelFatalError'                  "$f" 2>/dev/null && { echo "UE4 fatal error";                     return; }
  echo ""
}

cleanup() {
  [ -f "$CONF.try-backup" ] && mv -f "$CONF.try-backup" "$CONF"
  "$LAUNCH" --kill >/dev/null 2>&1
  pkill -f 'HelloNeighbor-Win64-Shipping' >/dev/null 2>&1
  wineserver -k >/dev/null 2>&1
  return 0
}
trap cleanup EXIT INT TERM

[ -f "$CONF" ] && cp -f "$CONF" "$CONF.try-backup"

printf '\n%sTrying %s configurations, %ss each. Nothing to click -- each one is\n' "$B$C" "${#ATTEMPTS[@]}" "$SECS"
printf 'stopped automatically. A window may flash open and shut each time.%s\n' "$N"
printf '%sIf one of them actually starts the game, let it run and press Ctrl-C.%s\n\n' "$B" "$N"

RESULTS=()
i=0
for row in "${ATTEMPTS[@]}"; do
  i=$((i+1))
  [ -n "$ONLY" ] && [ "$ONLY" != "$i" ] && continue

  IFS='|' read -r label defer wsi vdesk oneicd <<<"$row"
  printf '%s[%d/%d] %s%s\n' "$B" "$i" "${#ATTEMPTS[@]}" "$label" "$N"

  # write the dxvk.conf variant
  if [ -f "$CONF.try-backup" ]; then
    grep -v '^dxgi.deferSurfaceCreation' "$CONF.try-backup" > "$CONF"
    [ "$defer" = "1" ] && echo 'dxgi.deferSurfaceCreation = True' >> "$CONF"
  fi

  env_args=( "HN_VK_WSI_SW=$wsi" "HN_VIRTUAL_DESKTOP=$vdesk" "HN_GAME_LOG=1" )
  if [ "$oneicd" = "1" ] && [ -n "$VIRTIO_ICD" ]; then
    env_args+=( "VK_ICD_FILENAMES=$VIRTIO_ICD" "VK_DRIVER_FILES=$VIRTIO_ICD" )
  fi

  rm -f "$LOG_DIR"/launch-*.log 2>/dev/null
  start=$(date +%s)
  env "${env_args[@]}" timeout -k 5 "$SECS" "$LAUNCH" >/dev/null 2>&1
  elapsed=$(( $(date +%s) - start ))

  "$LAUNCH" --kill >/dev/null 2>&1
  pkill -f 'HelloNeighbor-Win64-Shipping' >/dev/null 2>&1
  wineserver -k >/dev/null 2>&1
  sleep 2

  logf="$LOG_DIR/latest.log"
  reason="$(classify "$logf")"

  if [ -z "$reason" ] && [ "$elapsed" -ge "$((SECS - 3))" ]; then
    verdict="${G}STILL RUNNING after ${elapsed}s -- this one works${N}"
    RESULTS+=("$i|RUNNING|$label")
  elif [ -z "$reason" ]; then
    verdict="${Y}exited after ${elapsed}s, no known error${N}"
    RESULTS+=("$i|quiet exit ${elapsed}s|$label")
  else
    verdict="${R}${reason} after ${elapsed}s${N}"
    RESULTS+=("$i|$reason|$label")
  fi
  printf '        %s\n\n' "$verdict"
done

cleanup
trap - EXIT

printf '%s================ SUMMARY ================%s\n' "$B$C" "$N"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r n outcome label <<<"$r"
  printf '  %s%-2s%s %-34s %s\n' "$B" "$n" "$N" "$outcome" "$label"
done
printf '\n'
printf 'Paste this summary back. If one says STILL RUNNING, tell me the number\n'
printf 'and I will make that configuration the permanent default.\n\n'
