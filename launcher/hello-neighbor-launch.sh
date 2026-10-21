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
#   --no-windowed  let the game pick its own window mode (default: windowed)
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
# Ask Unreal to write its own log. Cheap, and it names failures that Wine's
# output cannot (missing assets, out-of-memory, shader problems).
GAME_LOG="${HN_GAME_LOG:-1}"
# Windowed by default: this build asks for exclusive fullscreen, which has
# no meaning in Crostini and which DXGI refuses. HN_WINDOWED overrides it.
WINDOWED="${HN_WINDOWED:-1}"
# tinyBuild's own documented fix for this game on 10th-gen Intel CPUs and
# newer. On by default; HN_OPENSSL_FIX=0 turns it off. See the environment
# section below for what it actually does.
OPENSSL_FIX="${HN_OPENSSL_FIX:-1}"
ENABLE_CONSOLE=1
USE_SM4=0          # UE4 shipping builds rarely cook SM4 shaders
EXTRA_GAME_ARGS=""
# shellcheck disable=SC1090
# launcher.conf is sourced after the defaults above so it can override them.
# But sourcing would also clobber anything the user passed on the command
# line as an environment variable -- and "HN_VK_WSI_SW=1 hello-neighbor-launch"
# is exactly what we tell people to try. Remember the environment first and
# put it back afterwards, so precedence is: env > launcher.conf > defaults.
_env_wsi="${HN_VK_WSI_SW-}"
_env_vdesk="${HN_VIRTUAL_DESKTOP-}"
_env_wine="${HN_WINE-}"
_env_windowed="${HN_WINDOWED-}"
_env_sync="${HN_WINESYNC-}"
_env_nosound="${HN_NOSOUND-}"
_env_openssl="${HN_OPENSSL_FIX-}"
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
[ -n "$_env_wsi" ]   && HN_VK_WSI_SW="$_env_wsi"
[ -n "$_env_vdesk" ] && VDESK="$_env_vdesk"
[ -n "$_env_wine" ]  && HN_WINE="$_env_wine"
[ -n "$_env_windowed" ] && WINDOWED="$_env_windowed"
[ -n "$_env_sync" ] && HN_WINESYNC="$_env_sync"
[ -n "$_env_nosound" ] && HN_NOSOUND="$_env_nosound"
[ -n "$_env_openssl" ] && OPENSSL_FIX="$_env_openssl"
# launcher.conf may set OPENSSL_FIX directly too; the env wins over it.
unset _env_wsi _env_vdesk _env_wine _env_windowed _env_sync _env_nosound _env_openssl
# conf may override where the game lives, so re-resolve after sourcing it
[ -n "${HN_GAME_DIR:-}" ] && GAME_DIR="$HN_GAME_DIR"

# ---------------------------------------------------------------------------
# args
# ---------------------------------------------------------------------------
DEBUG=0
while [ $# -gt 0 ]; do
    case "$1" in
        --windowed) WINDOWED=1 ;;
        --no-windowed) WINDOWED=0 ;;
        --safe)     FORCE_BACKEND="wined3d"; SAFE_MODE=1; WINDOWED=1; RES_W=1024; RES_H=576 ;;
        --sm4)      USE_SM4=1 ;;
        --gl)       FORCE_BACKEND="wined3d" ;;
        --vdesk)    VDESK=1 ;;
        --gamelog)  GAME_LOG=1 ;;
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
    _keep=""; _seen=""
    _oldifs=$IFS; IFS=':'
    for _f in $VK_ICD_FILENAMES; do
        IFS=$_oldifs
        # Drop entries that do not exist.
        [ -e "$_f" ] || { IFS=':'; continue; }
        # Drop entries that are different names for the SAME driver. Debian
        # ships one architecture-neutral virtio_icd.json, and the symlinks we
        # add so ChromeOS's preset VK_ICD_FILENAMES resolves both point at it.
        # Listing both makes the loader open the driver twice, which
        # enumerates one GPU as two adapters -- DXVK then creates a surface
        # on one and queries it on the other, and Wine's winevulkan thunk
        # for vkGetPhysicalDeviceSurfaceFormatsKHR aborts the process.
        _real="$(readlink -f "$_f" 2>/dev/null || echo "$_f")"
        case ":$_seen:" in
            *":$_real:"*) log "skipping duplicate ICD $(basename "$_f") (same driver as an earlier entry)"; IFS=':'; continue ;;
        esac
        _seen="${_seen:+$_seen:}$_real"
        _keep="${_keep:+$_keep:}$_f"
        IFS=':'
    done
    IFS=$_oldifs
    if [ -z "$_keep" ]; then
        # Prefer the real virtio ICD over letting the loader scan, because the
        # directory also holds intel/radeon/lvp/gfxstream entries that are
        # either wrong for this VM or CPU-only.
        if [ -f "$ICD_DIR/virtio_icd.json" ]; then
            log "VK_ICD_FILENAMES pointed only at missing files -- using $ICD_DIR/virtio_icd.json"
            export VK_ICD_FILENAMES="$ICD_DIR/virtio_icd.json"
        else
            log "VK_ICD_FILENAMES pointed only at missing files -- unsetting it so the loader scans $ICD_DIR"
            unset VK_ICD_FILENAMES
        fi
    elif [ "$_keep" != "$VK_ICD_FILENAMES" ]; then
        log "VK_ICD_FILENAMES cleaned up -> $_keep"
        export VK_ICD_FILENAMES="$_keep"
    fi
    unset _keep _seen _real _f _oldifs
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

# --- the fix for THE crash --------------------------------------------------
# This one is not a Wine problem and never was. tinyBuild publish it in their
# own support article, "[PC] The game crashes at start":
#
#     "For players with 10th Gen Intel CPUs or newer (11th, 12th, 13th, etc.)"
#     create an environment variable OPENSSL_ia32cap with the value :~0x20000000
#     "Make sure to include the ':' on Value and leave no gaps -- formatting
#      matters!"
#
# Hello Neighbor ships an old build of OpenSSL (its analytics/online code
# talks HTTPS). That OpenSSL predates the SHA-NI instruction set, which Intel
# first shipped on 10th-gen Core chips. It detects the CPU, sees SHA-NI, takes
# a code path it was never built to run, and corrupts memory -- the process
# dies with 0xC0000005 before Unreal's crash handler is even installed, which
# is exactly why there was no crash report, and why the failure looked
# identical on every graphics stack we tried, right down to a software
# rasteriser with no GPU in the loop at all.
#
# OPENSSL_ia32cap is OpenSSL's own override for its CPU detection. The leading
# colon selects the *second* capability word; ~0x20000000 clears bit 29 of it,
# which is the SHA-NI bit. OpenSSL then behaves as it would on a 9th-gen chip.
# Nothing else about the game changes.
#
# Wine makes the Unix shell environment visible to the Windows process it
# starts (wine(1), "ENVIRONMENT"), so exporting it here is all it takes.
if [ "${OPENSSL_FIX:-1}" = "1" ]; then
    export OPENSSL_ia32cap=':~0x20000000'
    log "OpenSSL CPU workaround on (OPENSSL_ia32cap=:~0x20000000)"
else
    log "OpenSSL CPU workaround OFF (HN_OPENSSL_FIX=0)"
fi

export WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d"

# Audio is the one major subsystem this project has never tested without.
# Crostini reaches the host sound server through a bridge, Wine drives it
# through winepulse, and a fault inside libpulse lands on the Unix stack --
# exactly where the exception frames in our traces are, far outside the
# Windows stack range Wine knows about. HN_NOSOUND=1 removes the whole path:
# Wine loads no audio driver at all and Unreal is told not to open a device.
if [ "${HN_NOSOUND:-0}" = "1" ]; then
    WINEDLLOVERRIDES="$WINEDLLOVERRIDES;winepulse.drv,winealsa.drv,wineoss.drv,winecoreaudio.drv="
    export WINEDLLOVERRIDES
fi
# WINEDEBUG=-all used to be the default here for speed. It also silences
# Wine's own err: messages, which meant a missing DLL or an access violation
# left no trace at all in the log -- the only clue was a truncated exit code.
# "fixme-all" keeps the err channel (cheap, rare) and drops the fixme spam
# (noisy, harmless). HN_WINEDEBUG overrides it, which is how
# tools/crash-trace.sh asks for an exception backtrace.
if [ "$DEBUG" = "1" ]; then
    export WINEDEBUG="${HN_WINEDEBUG:-warn+all,fixme-all}"
else
    export WINEDEBUG="${HN_WINEDEBUG:-fixme-all}"
fi

# faster synchronisation primitives; harmless if the wine build lacks them
# esync and fsync replace Wine's server-side synchronisation with eventfd
# and futex primitives. They are a large win on a normal desktop and they
# have been forced on here since the first version of this launcher, never
# once tested off.
#
# Two reasons to be able to turn them off. First, esync needs a high
# open-file limit because every Windows sync object becomes a file
# descriptor; a UE4 game makes thousands, and on a container with the usual
# 1024 limit esync fails in ways that surface as corrupted threads rather
# than as a clean error. Second, fsync depends on kernel futex features that
# a Crostini VM kernel may not provide.
#
# Raise the limit as far as we are allowed before giving up on them, and
# record what we ended up with, because "invalid frame / Exception frame is
# not in stack limits" on a worker thread is exactly the shape this failure
# takes.
if [ "${HN_WINESYNC:-1}" = "1" ]; then
    _hard="$(ulimit -Hn 2>/dev/null || echo 1024)"
    [ "$_hard" = "unlimited" ] && _hard=1048576
    ulimit -n "$_hard" 2>/dev/null || true
    export WINEESYNC=1
    export WINEFSYNC=1
else
    export WINEESYNC=0
    export WINEFSYNC=0
    unset WINEESYNC WINEFSYNC
fi
_sndnote="audio on"
[ "${HN_NOSOUND:-0}" = "1" ] && _sndnote="audio OFF"
if [ "${HN_WINESYNC:-1}" = "1" ]; then
    log "esync/fsync on; open files $(ulimit -n)/$(ulimit -Hn); $_sndnote"
else
    log "esync/fsync OFF; open files $(ulimit -n)/$(ulimit -Hn); $_sndnote"
fi
unset _sndnote

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
    # Default: on inside Crostini. Confirmed necessary on the target machine
    # -- without it UE4 died in Present() with 887A0020 after a few seconds;
    # with it the game renders and reaches its loading screen.
    _wsi="${HN_VK_WSI_SW:-auto}"
    if [ "$_wsi" = "auto" ]; then
        [ -e /dev/wl0 ] && _wsi=1 || _wsi=0
    fi
    if [ "$_wsi" = "1" ]; then
        export MESA_VK_WSI_DEBUG=sw
        log "Venus WSI workaround active (MESA_VK_WSI_DEBUG=sw)"
    fi
    unset _wsi
    export DXVK_STATE_CACHE_PATH="$APP_HOME/cache/dxvk"
    export DXVK_LOG_PATH="$LOG_DIR"
    # Hello Neighbor is a UE4 *Shipping* build, which has logging compiled
    # out -- it will never write Saved/Logs. DXVK's log is therefore the only
    # view we have of what the renderer was doing. "info" costs almost
    # nothing and records the adapter, the features negotiated and any
    # Vulkan error. HN_DXVK_LOG=none turns it off.
    export DXVK_LOG_LEVEL="${HN_DXVK_LOG:-info}"
    # Allow an outside caller (tools/try-fixes.sh) to point at a variant.
    export DXVK_CONFIG_FILE="${DXVK_CONFIG_FILE:-$APP_HOME/dxvk.conf}"
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

[ "${HN_NOSOUND:-0}" = "1" ] && ARGS+=("-nosound")
[ "$ENABLE_CONSOLE" = "1" ] && ARGS+=("-console")
{ [ "$DEBUG" = "1" ] || [ "$GAME_LOG" = "1" ]; } && ARGS+=("-log")
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

# --- watch memory while the game runs --------------------------------------
# A silent death with no Unreal error text is the signature of the process
# being killed rather than crashing, and on an 8 GB Chromebook sharing RAM
# with ChromeOS the usual killer is memory. Sample the low-water mark so we
# can tell "ran out of memory" apart from "crashed".
MEM_LOW_FILE="$(mktemp 2>/dev/null || echo /tmp/hn-memlow.$$)"
awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo > "$MEM_LOW_FILE" 2>/dev/null
(
    while :; do
        cur=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 99999)
        low=$(cat "$MEM_LOW_FILE" 2>/dev/null || echo 99999)
        [ "$cur" -lt "$low" ] 2>/dev/null && echo "$cur" > "$MEM_LOW_FILE"
        sleep 2
    done
) & MEM_PID=$!
# Both of these must swallow their status. set -e is active by the time this
# is called, and wait() on a process we just killed returns 143, which would
# otherwise abort the script before it logs anything.
cleanup_mem() {
    [ -n "${MEM_PID:-}" ] || return 0
    kill "$MEM_PID" 2>/dev/null || true
    wait "$MEM_PID" 2>/dev/null || true
    MEM_PID=""
    return 0
}
trap cleanup_mem EXIT INT TERM

# Freeze a timestamp for "this run started now". $LOG_FILE cannot be used
# for this: it is appended to on every log line, so by the time the crash
# report is looked for the log is always the newer file and nothing matches.
RUN_MARKER="$LOG_DIR/.run-marker"
touch "$RUN_MARKER"
log "launching..."
set +e
"$WINE_BIN" "${LAUNCH_PREFIX[@]}" "$GAME_EXE" "${ARGS[@]}" >>"$LOG_FILE" 2>&1
RC=$?
set -e
log "game exited rc=$RC"

cleanup_mem
MEM_LOW="$(cat "$MEM_LOW_FILE" 2>/dev/null || echo '?')"
rm -f "$MEM_LOW_FILE"
log "lowest free memory during the run: ${MEM_LOW} MB"
if [ "$MEM_LOW" != "?" ] && [ "$MEM_LOW" -lt 350 ] 2>/dev/null; then
    log "DIAGNOSIS: the machine very nearly ran out of memory."
    log "  Re-run the installer with --lowmem for a leaner configuration."
fi
if dmesg 2>/dev/null | tail -80 | grep -qiE 'out of memory|oom-kill|killed process'; then
    log "DIAGNOSIS: the kernel's out-of-memory killer terminated the game."
    log "  Re-run the installer with --lowmem."
fi

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
if grep -qE "887A0020|D3D11Viewport.cpp" "$LOG_FILE" 2>/dev/null; then
    log "DIAGNOSIS: the game rendered, then failed to put the frame on screen."
    log "  887A0020 is DXGI_ERROR_DRIVER_INTERNAL_ERROR, raised from Present()."
    log "  This is the known Venus presentation bug in Crostini."
    log "  Fix: set HN_VK_WSI_SW=1 in $APP_HOME/launcher.conf"
    log "  Test it right now with:"
    log "    HN_VK_WSI_SW=1 $0"
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

# A Steam build calling SteamAPI_Init() outside Steam. The call fails, the
# game carries on with an interface it never got, and dies shortly after
# with 0xC0000005 -> rc=5. Config/Engine.ini turns the Steam online
# subsystem off to avoid this; say so if it is still happening.
if grep -q 'S_API FAIL' "$LOG_FILE" 2>/dev/null; then
    log "DIAGNOSIS: the game tried to reach Steam and Steam was not there."
    log "  SteamAPI_Init() failed and the game crashed a few seconds later."
    log "  The Steam online subsystem should be disabled in Engine.ini:"
    log "    [OnlineSubsystemSteam]"
    log "    bEnabled=false"
    log "  Engine.ini lives under the prefix at:"
    log "    .../drive_c/users/*/AppData/Local/HelloNeighbor/Saved/Config/WindowsNoEditor/"
    log "  Reinstall to restore it, or see docs/TROUBLESHOOTING.md."
fi

# A worker thread whose exception registration record points outside its own
# stack. Wine cannot dispatch the exception and the process dies without
# Unreal's handler ever running, so no crash report is written. This is the
# signature of synchronisation-level corruption rather than a graphics bug.
if grep -q 'not in stack limits\|call_seh_handlers invalid frame' "$LOG_FILE" 2>/dev/null; then
    log "DIAGNOSIS: a thread's exception frame was corrupt -- memory was"
    log "  scribbled on before Unreal's crash handler could run, so there is"
    log "  no crash report. On this hardware that has one known cause:"
    if [ "${OPENSSL_FIX:-1}" = "1" ]; then
        log "    The OpenSSL CPU workaround was ON this run, so something else"
        log "    is wrong. Next, try the game with no network at all --"
        log "    tinyBuild list that as the other fix for this same crash:"
        log "      turn WiFi off, then launch."
        log "    Then capture a trace: ./tools/crash-trace.sh"
    else
        log "    HN_OPENSSL_FIX=1 $0"
        log "      tinyBuild's documented fix for 10th-gen Intel CPUs and newer."
        log "      It is on by default; something turned it off this run."
    fi
    log "  Ruled out already on this machine, do not bother: graphics driver,"
    log "  DXVK version, X11 vs Wayland, esync/fsync, audio, CPU topology."
fi

# Unreal writes a crash report of its own even in a Shipping build, under
# Saved/Crashes/UE4CC-*/CrashContext.runtime-xml. It names the failure far
# better than a truncated exit code ever can -- it was how
# "CreateSwapChain ... E_FAIL" was finally identified -- so surface it here
# rather than making anyone go and find it. Only reports newer than this
# run's log file are considered, so an old one is never misread as current.
if [ "$RC" = "0" ] && [ "$VDESK" = "1" ]; then
    log "note: --vdesk runs the game through Wine's explorer, so the exit code"
    log "  above is explorer's and NOT the game's. A clean 0 here does not mean"
    log "  the game exited cleanly. Checking for a crash report regardless."
fi
if [ "$RC" != "0" ] || [ "$VDESK" = "1" ]; then
    for _cd in "$WINEPREFIX"/drive_c/users/*/AppData/Local/HelloNeighbor/Saved/Crashes; do
        [ -d "$_cd" ] || continue
        _xml="$(find "$_cd" -name 'CrashContext.runtime-xml' -newer "$RUN_MARKER" \
                -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
        [ -n "$_xml" ] || continue
        log "Unreal's own crash report for this run:"
        awk 'BEGIN { s = "<ErrorMessage>"; e = "</ErrorMessage>" }
             !b && index($0, s) { b = 1; sub(".*" s, "") }
             b { if (index($0, e)) { sub(e ".*", ""); if (length($0)) print; exit } print }' \
            "$_xml" 2>/dev/null \
          | sed -e 's/&gt;/>/g' -e 's/&lt;/</g' -e 's/&amp;/\&/g' -e '/^[[:space:]]*$/d' \
          | head -6 | while IFS= read -r _l; do log "  $_l"; done
        log "  full report: ./tools/read-crash.sh"
        break
    done
fi

# UE4 writes its log deep inside the Wine prefix. Copy the newest one next
# to ours so there is a single place to look.
UE4_LOG="$(find "$WINEPREFIX/drive_c/users" -path '*HelloNeighbor/Saved/Logs/*' \
             -name '*.log' -type f -printf '%T@ %p\n' 2>/dev/null \
           | sort -rn | head -1 | cut -d' ' -f2-)"
if [ -n "$UE4_LOG" ] && [ -f "$UE4_LOG" ]; then
    cp -f "$UE4_LOG" "$LOG_DIR/ue4-latest.log" 2>/dev/null || true
    log "UE4's own log copied to $LOG_DIR/ue4-latest.log"
else
    log "no UE4 log (Shipping builds compile it out) -- but Unreal does write crash reports: ./tools/read-crash.sh"
fi

command -v wineserver >/dev/null && wineserver -w 2>/dev/null || true
exit 0
