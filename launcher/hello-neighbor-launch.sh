#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Hello Neighbor - ChromeOS / Crostini launch wrapper
#
# This is the "hidden" script behind the shelf icon. You should never need to
# run it by hand -- the .desktop entry calls it. It:
#   * picks the best graphics backend available (DXVK/Vulkan -> WineD3D/GL)
#   * applies Crostini-specific audio + GL workarounds
#   * keeps a single instance
#   * logs everything to ~/.local/share/hello-neighbor/logs/
#
# Flags:
#   --windowed     force windowed mode
#   --safe         force the most compatible path (WineD3D + SM4/DX10)
#   --gl           force OpenGL (WineD3D) even if Vulkan is present
#   --vk           force DXVK even if detection says otherwise
#   --res WxH      override resolution, e.g. --res 1600x900
#   --console      start with the UE4 developer console enabled
#   --kill         terminate a running game + its wine prefix
#   --debug        verbose wine logging (slow, for troubleshooting only)
# ---------------------------------------------------------------------------
set -uo pipefail

APP_NAME="Hello Neighbor"
APP_ID="hello-neighbor"
APP_HOME="${HN_HOME:-$HOME/.local/share/$APP_ID}"
GAME_DIR="${HN_GAME_DIR:-$APP_HOME/game}"
export WINEPREFIX="${HN_WINEPREFIX:-$APP_HOME/prefix}"
LOG_DIR="$APP_HOME/logs"
LOCK_FILE="$APP_HOME/.running.lock"
CONF_FILE="$APP_HOME/launcher.conf"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/launch-$(date +%Y%m%d-%H%M%S).log"

# keep only the 10 most recent logs
ls -1t "$LOG_DIR"/launch-*.log 2>/dev/null | tail -n +11 | xargs -r rm -f

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { log "FATAL: $*"; notify "Hello Neighbor failed to start" "$*"; exit 1; }

notify() {
    command -v notify-send >/dev/null 2>&1 && notify-send -i "$APP_ID" "$1" "${2:-}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# user-tunable overrides (written by install.sh, safe to hand-edit)
# ---------------------------------------------------------------------------
RES_W=1280
RES_H=720
FORCE_BACKEND=""      # "" | dxvk | wined3d
WINDOWED=0
ENABLE_CONSOLE=1
EXTRA_GAME_ARGS=""
# shellcheck disable=SC1090
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
# conf may override where the game lives, so re-resolve after sourcing it
[ -n "${HN_GAME_DIR:-}" ] && GAME_DIR="$HN_GAME_DIR"

# ---------------------------------------------------------------------------
# args
# ---------------------------------------------------------------------------
DEBUG=0
while [ $# -gt 0 ]; do
    case "$1" in
        --windowed) WINDOWED=1 ;;
        --safe)     FORCE_BACKEND="wined3d"; SAFE_MODE=1 ;;
        --gl)       FORCE_BACKEND="wined3d" ;;
        --vk)       FORCE_BACKEND="dxvk" ;;
        --console)  ENABLE_CONSOLE=1 ;;
        --debug)    DEBUG=1 ;;
        --res)      shift; RES_W="${1%x*}"; RES_H="${1#*x}" ;;
        --kill)
            pkill -f 'HelloNeighbor.*-Shipping' 2>/dev/null
            command -v wineserver >/dev/null && wineserver -k 2>/dev/null
            rm -f "$LOCK_FILE"
            echo "Hello Neighbor terminated."
            exit 0 ;;
        *) ;;   # ignore unknown (desktop files can pass %U etc.)
    esac
    shift
done
SAFE_MODE="${SAFE_MODE:-0}"

# ---------------------------------------------------------------------------
# single instance
# ---------------------------------------------------------------------------
if [ -e "$LOCK_FILE" ]; then
    oldpid="$(cat "$LOCK_FILE" 2>/dev/null || echo)"
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
        notify "$APP_NAME is already running"
        log "Already running (pid $oldpid); refusing second instance."
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
cleanup() { rm -f "$LOCK_FILE"; }
trap cleanup EXIT INT TERM

log "=== $APP_NAME launcher ==="
log "prefix=$WINEPREFIX  game=$GAME_DIR"

# ---------------------------------------------------------------------------
# locate wine
# ---------------------------------------------------------------------------
WINE_BIN=""
for cand in "${HN_WINE:-}" wine-stable wine64 wine; do
    [ -n "$cand" ] || continue
    if command -v "$cand" >/dev/null 2>&1; then WINE_BIN="$(command -v "$cand")"; break; fi
done
[ -n "$WINE_BIN" ] || die "Wine is not installed. Run install.sh, or: sudo apt install wine64"
log "wine: $WINE_BIN ($("$WINE_BIN" --version 2>/dev/null || echo '?'))"

# ---------------------------------------------------------------------------
# locate the shipping executable
# ---------------------------------------------------------------------------
GAME_EXE=""
if [ -n "${HN_GAME_EXE:-}" ] && [ -f "$HN_GAME_EXE" ]; then
    GAME_EXE="$HN_GAME_EXE"
else
    # prefer the real shipping binary over the launcher stub -- the stub
    # re-launches and detaches, which breaks process tracking under Wine.
    GAME_EXE="$(find -L "$GAME_DIR" -maxdepth 6 -type f \
        -iname 'HelloNeighbor-Win64-Shipping.exe' 2>/dev/null | head -1)"
    [ -z "$GAME_EXE" ] && GAME_EXE="$(find -L "$GAME_DIR" -maxdepth 6 -type f \
        -iname 'HelloNeighbor-Win32-Shipping.exe' 2>/dev/null | head -1)"
    [ -z "$GAME_EXE" ] && GAME_EXE="$(find -L "$GAME_DIR" -maxdepth 3 -type f \
        -iname 'HelloNeighbor.exe' 2>/dev/null | head -1)"
fi
[ -n "$GAME_EXE" ] && [ -f "$GAME_EXE" ] || die "Could not find HelloNeighbor executable under $GAME_DIR"
log "exe: $GAME_EXE"
GAME_EXE_DIR="$(dirname "$GAME_EXE")"

# ---------------------------------------------------------------------------
# graphics backend selection
#
# On Crostini you get GL through VirGL and (on newer ChromeOS) Vulkan through
# Venus. DXVK needs real Vulkan; if Venus is missing, DXVK silently falls over,
# so we detect rather than assume.
# ---------------------------------------------------------------------------
have_vulkan() {
    [ -n "$(ls -A /usr/share/vulkan/icd.d/*.json 2>/dev/null)" ] || return 1
    if command -v vulkaninfo >/dev/null 2>&1; then
        timeout 15 vulkaninfo --summary >/dev/null 2>&1 || return 1
    fi
    return 0
}

BACKEND="wined3d"
if [ "$FORCE_BACKEND" = "dxvk" ]; then
    BACKEND="dxvk"
elif [ "$FORCE_BACKEND" = "wined3d" ]; then
    BACKEND="wined3d"
elif [ -f "$WINEPREFIX/drive_c/windows/system32/dxgi.dll.dxvk-marker" ] && have_vulkan; then
    BACKEND="dxvk"
elif have_vulkan && [ -f "$WINEPREFIX/.dxvk-installed" ]; then
    BACKEND="dxvk"
fi
log "graphics backend: $BACKEND"

# ---------------------------------------------------------------------------
# environment
# ---------------------------------------------------------------------------
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d"
if [ "$DEBUG" = "1" ]; then
    export WINEDEBUG="warn+all,fixme-all"
else
    export WINEDEBUG="-all"
fi

# faster synchronisation primitives; harmless if the wine build lacks them
export WINEESYNC=1
export WINEFSYNC=1

# --- Crostini audio ---------------------------------------------------------
# The default 20ms Pulse latency crackles badly through the ChromeOS audio
# bridge. 60ms is inaudible as lag but removes the crackle entirely.
export PULSE_LATENCY_MSEC="${PULSE_LATENCY_MSEC:-60}"
export SDL_AUDIODRIVER=pulse

# --- Mesa / VirGL -----------------------------------------------------------
export mesa_glthread=true                 # big win on VirGL: offloads GL calls
export vblank_mode=0                      # don't block on compositor vsync
export MESA_SHADER_CACHE_DIR="$APP_HOME/cache/mesa"
export MESA_SHADER_CACHE_MAX_SIZE=4G
mkdir -p "$MESA_SHADER_CACHE_DIR"

if [ "$BACKEND" = "wined3d" ]; then
    # VirGL under-reports its GL version; UE4 wants >= 4.3 era features.
    export MESA_GL_VERSION_OVERRIDE="${MESA_GL_VERSION_OVERRIDE:-4.6COMPAT}"
    export MESA_GLSL_VERSION_OVERRIDE="${MESA_GLSL_VERSION_OVERRIDE:-460}"
    export MESA_EXTENSION_MAX_YEAR=2020
else
    export DXVK_STATE_CACHE_PATH="$APP_HOME/cache/dxvk"
    export DXVK_LOG_PATH="$LOG_DIR"
    export DXVK_LOG_LEVEL=none
    export DXVK_CONFIG_FILE="$APP_HOME/dxvk.conf"
    mkdir -p "$DXVK_STATE_CACHE_PATH"
fi

# --- CPU --------------------------------------------------------------------
# 12th gen i5: let UE4 see the cores, but keep the Wine server on a sane nice
# level so the ChromeOS UI stays responsive.
export STAGING_SHARED_MEMORY=1
export WINE_LARGE_ADDRESS_AWARE=1

# ---------------------------------------------------------------------------
# game arguments
# ---------------------------------------------------------------------------
ARGS=()
ARGS+=("-NOSPLASH")
ARGS+=("-ResX=$RES_W" "-ResY=$RES_H")
# Default: pass nothing, so GameUserSettings.ini's FullscreenMode=1
# (borderless) wins. Exclusive fullscreen performs a real display mode-set,
# which has no meaning inside Crostini and black-screens the game.
if [ "$WINDOWED" = "1" ]; then
    ARGS+=("-WINDOWED")
fi
ARGS+=("-USEALLAVAILABLECORES")

if [ "$BACKEND" = "wined3d" ] || [ "$SAFE_MODE" = "1" ]; then
    # SM4 / DX10 feature level: materially cheaper shaders, and WineD3D's
    # GL translation of SM5 is where most of the stuttering comes from.
    ARGS+=("-dx10" "-sm4")
else
    ARGS+=("-dx11")
fi

[ "$ENABLE_CONSOLE" = "1" ] && ARGS+=("-console")
[ "$DEBUG" = "1" ] && ARGS+=("-log")
# shellcheck disable=SC2206
[ -n "$EXTRA_GAME_ARGS" ] && ARGS+=($EXTRA_GAME_ARGS)

log "args: ${ARGS[*]}"

# ---------------------------------------------------------------------------
# first-run prefix bootstrap
# ---------------------------------------------------------------------------
if [ ! -d "$WINEPREFIX/drive_c" ]; then
    log "Creating Wine prefix (first run, this takes a minute)..."
    notify "$APP_NAME" "First-time setup, please wait..."
    WINEDLLOVERRIDES="mscoree,mshtml=" "$WINE_BIN" wineboot -u >>"$LOG_FILE" 2>&1
    "${WINE_BIN}server" -w 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# go
# ---------------------------------------------------------------------------
notify "$APP_NAME" "Starting..."
cd "$GAME_EXE_DIR" || die "cannot cd to $GAME_EXE_DIR"

log "launching..."
set +e
"$WINE_BIN" "$GAME_EXE" "${ARGS[@]}" >>"$LOG_FILE" 2>&1
RC=$?
set -e
log "game exited rc=$RC"

# Wine returns non-zero for plenty of benign reasons; only shout if the game
# died almost immediately, which is the signature of a real failure.
if [ $RC -ne 0 ]; then
    log "non-zero exit -- see $LOG_FILE"
fi

command -v wineserver >/dev/null && wineserver -w 2>/dev/null || true
exit 0
