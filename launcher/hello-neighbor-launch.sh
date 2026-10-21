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
#   --vdesk        run inside a Wine virtual desktop (fixes CreateSwapChain)
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
# Stable name so "read the log" is always the same command, however many
# timestamped runs have piled up.
LATEST_LINK="$LOG_DIR/latest.log"
ln -sfn "$(basename "$LOG_FILE")" "$LATEST_LINK" 2>/dev/null || true

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
# Wine virtual desktop. Crostini's X server (sommelier) manages windows
# differently from a normal desktop, and UE4 sometimes cannot get a Vulkan
# surface for the window it just made -- CreateSwapChain then fails with
# E_FAIL. Running inside "wine explorer /desktop=..." gives Wine one real
# top-level X window that it owns outright, which sidesteps that.
VDESK="${HN_VIRTUAL_DESKTOP:-0}"
WINDOWED=0
ENABLE_CONSOLE=1
USE_SM4=0          # UE4 shipping builds rarely cook SM4 shaders
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
        --safe)     FORCE_BACKEND="wined3d"; SAFE_MODE=1; WINDOWED=1; RES_W=1024; RES_H=576 ;;
        --sm4)      USE_SM4=1 ;;
        --gl)       FORCE_BACKEND="wined3d" ;;
        --vdesk)    VDESK=1 ;;
        --no-vdesk) VDESK=0 ;;
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
# ChromeOS presets VK_ICD_FILENAMES to virtio_icd.{i686,x86_64}.json, but
# Debian's Mesa ships the file as virtio_icd.json. A set-but-dangling
# VK_ICD_FILENAMES is worse than an unset one: the loader honours it and skips
# its own directory scan, so a perfectly good driver is reported as absent.
# Drop entries that do not exist; unset the variable entirely if none survive.
sanitise_vk_icd() {
    [ -n "${VK_ICD_FILENAMES:-}" ] || return 0
    _keep=""
    _oldifs=$IFS; IFS=':'
    for _f in $VK_ICD_FILENAMES; do
        [ -e "$_f" ] && _keep="${_keep:+$_keep:}$_f"
    done
    IFS=$_oldifs
    if [ -z "$_keep" ]; then
        log "VK_ICD_FILENAMES pointed only at missing files -- unsetting it so the loader scans $ICD_DIR"
        unset VK_ICD_FILENAMES
    elif [ "$_keep" != "$VK_ICD_FILENAMES" ]; then
        log "pruned dangling VK_ICD_FILENAMES entries -> $_keep"
        export VK_ICD_FILENAMES="$_keep"
    fi
}

ICD_DIR=/usr/share/vulkan/icd.d
sanitise_vk_icd

have_vulkan() {
    [ -n "$(ls -A "$ICD_DIR"/*.json 2>/dev/null)" ] || return 1
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
    # Venus (Crostini's Vulkan driver) has a known bug presenting frames
    # through X11/XWayland: the swapchain either tears badly or hangs on the
    # first present. MESA_VK_WSI_DEBUG=sw moves ONLY the final "copy the
    # finished frame to the window" step onto the CPU. All rendering stays on
    # the GPU, so the cost is a few percent, not a fallback to software.
    # Set HN_VK_WSI_SW=1 in launcher.conf to enable it.
    # Default OFF. Forcing the software present path changes which surface
    # capabilities Venus advertises, and that can itself make
    # vkCreateSwapchainKHR fail -- which surfaces as UE4's
    # "CreateSwapChain ... E_FAIL". Only turn it on if the game renders but
    # tears or freezes on presentation.
    if [ "${HN_VK_WSI_SW:-0}" = "1" ]; then
        export MESA_VK_WSI_DEBUG=sw
        log "Venus WSI workaround active (MESA_VK_WSI_DEBUG=sw)"
    fi
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
    # Plain D3D11. Do NOT add -dx10/-sm4 by default: UE4 shipping builds
    # normally only cook SM5 shaders, so forcing Shader Model 4 makes the
    # renderer ask for shaders that were never packaged. It gets null back
    # and writes to it, which surfaces as:
    #   "Unhandled page fault on write access to 0000000000000000"
    # before Unreal has even opened its own log file.
    # Opt in with --sm4 only if you know this build cooked SM4 shaders.
    if [ "$USE_SM4" = "1" ]; then
        ARGS+=("-dx10" "-sm4")
    fi
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

LAUNCH_PREFIX=()
if [ "$VDESK" = "1" ]; then
    LAUNCH_PREFIX=(explorer "/desktop=HelloNeighbor,${RES_W}x${RES_H}")
    log "virtual desktop: ${RES_W}x${RES_H}"
fi

log "launching..."
set +e
"$WINE_BIN" "${LAUNCH_PREFIX[@]}" "$GAME_EXE" "${ARGS[@]}" >>"$LOG_FILE" 2>&1
RC=$?
set -e
log "game exited rc=$RC"

# Wine returns non-zero for plenty of benign reasons; only shout if the game
# died almost immediately, which is the signature of a real failure.
if [ $RC -ne 0 ]; then
    log "non-zero exit -- see $LOG_FILE"
fi

# Turn the two failures we have actually hit into plain-English advice rather
# than leaving the user to read a UE4 fatal-error dump.
if grep -q "CreateSwapChain" "$LOG_FILE" 2>/dev/null; then
    log "DIAGNOSIS: the game could not create its display surface."
    log "  Try, in order:"
    log "    1. $0 --vdesk            (run inside a Wine virtual desktop)"
    log "    2. $0 --vdesk --windowed"
    log "    3. set HN_VK_WSI_SW=1 in $APP_HOME/launcher.conf"
fi
if grep -q "loader_thunks.c" "$LOG_FILE" 2>/dev/null; then
    log "DIAGNOSIS: Wine is too old for the Vulkan driver installed."
    log "  winevulkan was asked to forward a call it was not built to handle."
    log "  Fix: ./install.sh --game-dir <dir> --no-deps --dxvk-ver 1.10.3"
    log "  Or upgrade Wine:  ./install.sh --game-dir <dir> --winehq"
fi
if grep -q "GL_RGBA8_SNORM" "$LOG_FILE" 2>/dev/null; then
    log "DIAGNOSIS: running on WineD3D, which cannot render this game."
    log "  Install the Vulkan driver: ./tools/enable-vulkan.sh"
fi

command -v wineserver >/dev/null && wineserver -w 2>/dev/null || true
exit 0
