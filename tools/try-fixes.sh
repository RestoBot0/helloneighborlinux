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
#  Every attempt's logs are KEPT, under logs/try-fixes/, so a crash with no
#  recognised signature can still be investigated afterwards.
#
#  Nothing is left modified: dxvk.conf is restored on every exit path.
#
#  Usage:  ./tools/try-fixes.sh [--seconds N] [--only N] [--tail N]
#            --seconds N   how long to let each attempt run (default 45)
#            --only N      run just attempt number N (repeatable: --only 1,2)
#            --tail N      lines of log to print for the best attempt (20)
# ===========================================================================
set -uo pipefail

APP_ID="hello-neighbor"
APP_HOME="$HOME/.local/share/$APP_ID"
LAUNCH="$APP_HOME/bin/$APP_ID-launch"
CONF="$APP_HOME/dxvk.conf"
LOG_DIR="$APP_HOME/logs"
SAVE_DIR="$LOG_DIR/try-fixes"
SECS=45
ONLY=""
TAIL_N=20

while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) shift; SECS="${1:-45}" ;;
    --only)    shift; ONLY="${1:-}" ;;
    --tail)    shift; TAIL_N="${1:-20}" ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ -t 1 ]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
else B=""; G=""; Y=""; R=""; C=""; N=""; fi

[ -x "$LAUNCH" ] || { echo "Launcher not found at $LAUNCH -- run install.sh first." >&2; exit 1; }

wanted() { # wanted <n> -- is this attempt selected?
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in *",$1,"*) return 0 ;; esac
  return 1
}

ICD_DIR=/usr/share/vulkan/icd.d
VIRTIO_ICD=""
for cand in "$ICD_DIR/virtio_icd.x86_64.json" "$ICD_DIR/virtio_icd.json"; do
  [ -e "$cand" ] && { VIRTIO_ICD="$cand"; break; }
done

# --- the attempts -----------------------------------------------------------
# label | defer surface creation | WSI software present | virtual desktop |
# force a single Vulkan driver
#
# The first two were added to work around Wine 8 bugs. Wine is now 11.x, so
# they are suspects for causing harm rather than helping: both change when and
# how the Vulkan surface is created.
ATTEMPTS=(
  "stock Wine 11 behaviour (no Wine 8 workarounds)|0|0|0|0"
  "software frame presentation only|0|1|0|0"
  "deferred surface creation only|1|0|0|0"
  "both Wine 8 workarounds|1|1|0|0"
  "software present + single Vulkan driver|0|1|0|1"
  "software present + Wine virtual desktop|0|1|1|0"
)

# Known failure signatures, most specific first.
classify() { # classify <logfile>
  local f="$1"
  [ -f "$f" ] || { echo "launcher produced no log"; return; }
  grep -q 'vkGetPhysicalDeviceSurfaceFormatsKHR' "$f" 2>/dev/null && { echo "winevulkan assert (surface formats)"; return; }
  grep -q 'loader_thunks.c'                      "$f" 2>/dev/null && { echo "winevulkan assert (other)";           return; }
  grep -q '887A0020'                             "$f" 2>/dev/null && { echo "Present() failed 887A0020";           return; }
  grep -q 'CreateSwapChain'                      "$f" 2>/dev/null && { echo "CreateSwapChain failed";              return; }
  grep -q 'GL_RGBA8_SNORM'                       "$f" 2>/dev/null && { echo "WineD3D path (no Vulkan)";            return; }
  grep -qi 'No adapters found'                   "$f" 2>/dev/null && { echo "DXVK found no adapter";               return; }
  grep -qi 'LowLevelFatalError'                  "$f" 2>/dev/null && { echo "UE4 fatal error";                     return; }
  grep -qi 'out of memory\|VK_ERROR_OUT_OF'      "$f" 2>/dev/null && { echo "out of memory";                       return; }
  grep -qi 'Unhandled exception\|page fault'     "$f" 2>/dev/null && { echo "unhandled exception";                 return; }
  grep -qi 'DeviceLost\|VK_ERROR_DEVICE_LOST'    "$f" 2>/dev/null && { echo "GPU device lost";                     return; }
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
rm -rf "$SAVE_DIR"; mkdir -p "$SAVE_DIR"

printf '\n%sTrying configurations, %ss each. Nothing to click -- each one is\n' "$B$C" "$SECS"
printf 'stopped automatically. A window may flash open and shut each time.%s\n' "$N"
printf '%sIf one of them actually starts the game, let it run and press Ctrl-C.%s\n\n' "$B" "$N"

RESULTS=()
BEST_N=0; BEST_SECS=-1; BEST_LOG=""
i=0
for row in "${ATTEMPTS[@]}"; do
  i=$((i+1))
  wanted "$i" || continue

  IFS='|' read -r label defer wsi vdesk oneicd <<<"$row"
  printf '%s[%d/%d] %s%s\n' "$B" "$i" "${#ATTEMPTS[@]}" "$label" "$N"

  if [ -f "$CONF.try-backup" ]; then
    grep -v '^dxgi.deferSurfaceCreation' "$CONF.try-backup" > "$CONF"
    [ "$defer" = "1" ] && echo 'dxgi.deferSurfaceCreation = True' >> "$CONF"
  fi

  env_args=( "HN_VK_WSI_SW=$wsi" "HN_VIRTUAL_DESKTOP=$vdesk" "HN_GAME_LOG=1" "HN_DXVK_LOG=info" )
  if [ "$oneicd" = "1" ] && [ -n "$VIRTIO_ICD" ]; then
    env_args+=( "VK_ICD_FILENAMES=$VIRTIO_ICD" "VK_DRIVER_FILES=$VIRTIO_ICD" )
  fi

  rm -f "$LOG_DIR"/launch-*.log "$LOG_DIR"/*_d3d11.log "$LOG_DIR"/*_dxgi.log 2>/dev/null
  start=$(date +%s)
  env "${env_args[@]}" timeout -k 5 "$SECS" "$LAUNCH" >/dev/null 2>&1
  elapsed=$(( $(date +%s) - start ))

  "$LAUNCH" --kill >/dev/null 2>&1
  pkill -f 'HelloNeighbor-Win64-Shipping' >/dev/null 2>&1
  wineserver -k >/dev/null 2>&1
  sleep 2

  # Keep everything this attempt produced, launcher and DXVK kept apart so
  # neither buries the other when we tail them.
  saved="$SAVE_DIR/attempt-$i.log"
  saved_gpu="$SAVE_DIR/attempt-$i-dxvk.log"
  {
    echo "### attempt $i: $label"
    echo "### defer=$defer wsi_sw=$wsi vdesk=$vdesk single_icd=$oneicd  ran ${elapsed}s"
    echo
    cat "$LOG_DIR"/launch-*.log 2>/dev/null
  } > "$saved" 2>/dev/null
  {
    for d in "$LOG_DIR"/*_dxgi.log "$LOG_DIR"/*_d3d11.log; do
      [ -f "$d" ] || continue
      echo "### $(basename "$d")"; cat "$d"; echo
    done
  } > "$saved_gpu" 2>/dev/null

  rc="$(grep -o 'game exited rc=[0-9]*' "$saved" 2>/dev/null | tail -1 | cut -d= -f2)"
  [ -n "$rc" ] || rc="?"
  reason="$(classify "$saved")"
  [ -n "$reason" ] || reason="$(classify "$saved_gpu")"

  if [ -z "$reason" ] && [ "$elapsed" -ge "$((SECS - 3))" ]; then
    verdict="${G}STILL RUNNING after ${elapsed}s -- this one works${N}"
    outcome="RUNNING"
  elif [ -z "$reason" ]; then
    verdict="${Y}exited after ${elapsed}s (rc=$rc), no recognised error${N}"
    outcome="quiet exit rc=$rc"
  else
    verdict="${R}${reason} after ${elapsed}s${N}"
    outcome="$reason"
  fi
  printf '        %s\n\n' "$verdict"
  RESULTS+=("$i|$outcome|${elapsed}s|$label")

  if [ "$elapsed" -gt "$BEST_SECS" ]; then
    BEST_SECS="$elapsed"; BEST_N="$i"; BEST_LOG="$saved"
  fi
done

cleanup
trap - EXIT

printf '%s================ SUMMARY ================%s\n' "$B$C" "$N"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r n outcome secs label <<<"$r"
  printf '  %s%-2s%s %-6s %-34s %s\n' "$B" "$n" "$N" "$secs" "$outcome" "$label"
done
printf '\n'

if [ -n "$BEST_LOG" ] && [ -f "$BEST_LOG" ]; then
  printf '%s===== attempt %s (survived longest, %ss) -- last %s launcher lines =====%s\n' \
    "$B$C" "$BEST_N" "$BEST_SECS" "$TAIL_N" "$N"
  tail -n "$TAIL_N" "$BEST_LOG"
  if [ -s "${BEST_LOG%.log}-dxvk.log" ]; then
    printf '\n%s===== attempt %s -- last %s DXVK lines =====%s\n' "$B$C" "$BEST_N" "$TAIL_N" "$N"
    tail -n "$TAIL_N" "${BEST_LOG%.log}-dxvk.log"
  fi
  printf '\n'
fi

printf 'Full logs for every attempt are kept in:\n  %s\n\n' "$SAVE_DIR"
printf 'Paste the summary and the lines above back to me.\n\n'
