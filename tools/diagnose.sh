#!/usr/bin/env bash
# ===========================================================================
#  diagnose.sh -- collect everything needed to explain a crash, in one go
#
#  Prints a single report: the machine, the graphics stack, the launcher's
#  log, DXVK's log and any Unreal log. Paste the whole thing when asking for
#  help rather than hunting through files.
#
#  Usage:  ./tools/diagnose.sh [--lines N]     (default 40 lines per log)
# ===========================================================================
set -uo pipefail

APP_ID="hello-neighbor"
APP_HOME="$HOME/.local/share/$APP_ID"
LOG_DIR="$APP_HOME/logs"
LINES=40

while [ $# -gt 0 ]; do
  case "$1" in
    --lines) shift; LINES="${1:-40}" ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

sec() { printf '\n========== %s ==========\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

sec "SYSTEM"
echo "date       : $(date)"
echo "kernel     : $(uname -r)"
echo "distro     : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
echo "cpu        : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
echo "ram total  : $(awk '/MemTotal/{printf "%d MB", $2/1024}' /proc/meminfo)"
echo "ram avail  : $(awk '/MemAvailable/{printf "%d MB", $2/1024}' /proc/meminfo)"
echo "swap       : $(awk '/SwapTotal/{printf "%d MB", $2/1024}' /proc/meminfo)"
echo "crostini   : $([ -e /dev/wl0 ] && echo yes || echo no)"

sec "GRAPHICS"
if have vulkaninfo; then
  timeout 20 vulkaninfo --summary 2>/dev/null \
    | grep -iE 'driverName|deviceName|apiVersion|deviceType|driverVersion' | sed 's/^[[:space:]]*/  /'
else
  echo "  vulkaninfo not installed"
fi
echo "  ICDs: $(ls /usr/share/vulkan/icd.d/ 2>/dev/null | tr '\n' ' ')"
echo "  VK_ICD_FILENAMES=${VK_ICD_FILENAMES:-<unset>}"
have glxinfo && echo "  GL: $(glxinfo -B 2>/dev/null | grep -i 'OpenGL renderer' | cut -d: -f2-)"
have wine && echo "  wine: $(wine --version 2>/dev/null)"
echo "  mesa pkg: $(dpkg-query -W -f='${Version}' mesa-vulkan-drivers 2>/dev/null || echo '?')"

sec "INSTALL"
echo "  app home : $APP_HOME"
echo "  dxvk     : $([ -f "$APP_HOME/prefix/.dxvk-installed" ] && echo installed || echo 'not installed')"
for d in d3d11 dxgi; do
  f="$APP_HOME/prefix/drive_c/windows/system32/$d.dll"
  [ -f "$f" ] && echo "  $d.dll  : $(stat -c%s "$f") bytes"
done
echo "  desktop  : $(ls "$HOME/.local/share/applications/" 2>/dev/null | grep -c hello-neighbor) entry/entries"

sec "launcher.conf"
[ -f "$APP_HOME/launcher.conf" ] && grep -vE '^\s*#|^\s*$' "$APP_HOME/launcher.conf" | sed 's/^/  /' || echo "  missing"

sec "dxvk.conf"
[ -f "$APP_HOME/dxvk.conf" ] && grep -vE '^\s*#|^\s*$' "$APP_HOME/dxvk.conf" | sed 's/^/  /' || echo "  missing"

sec "LAUNCHER LOG (last $LINES lines)"
if [ -f "$LOG_DIR/latest.log" ]; then tail -n "$LINES" "$LOG_DIR/latest.log"; else echo "  none"; fi

sec "DXVK LOGS"
found=0
for f in "$LOG_DIR"/*.log; do
  case "$(basename "$f")" in
    launch-*|latest.log|ue4-latest.log) continue ;;
  esac
  [ -f "$f" ] || continue
  found=1
  echo "--- $(basename "$f") ---"
  tail -n "$LINES" "$f"
done
[ "$found" = "1" ] || echo "  none yet -- DXVK logging is on by default from this version onwards"

sec "UE4 LOG"
u="$(find "$APP_HOME/prefix/drive_c/users" -path '*Saved/Logs/*' -name '*.log' -type f 2>/dev/null | head -1)"
if [ -n "$u" ]; then tail -n "$LINES" "$u"; else
  echo "  none. Hello Neighbor is a UE4 Shipping build and Shipping compiles"
  echo "  logging out, so this is expected -- not a sign of anything wrong."
fi

sec "END"
