#!/usr/bin/env bash
# ===========================================================================
#  Hello Neighbor -> ChromeOS (Crostini) one-click installer
#
#  Run this INSIDE the Linux terminal on your Chromebook. Exactly once.
#  Afterwards the game is a normal icon in your ChromeOS launcher/shelf.
#
#  Usage:
#     ./install.sh --rar ~/Downloads/HelloNeighbor.rar
#     ./install.sh --game-dir ~/Downloads/HelloNeighbor      (already extracted)
#
#  Options:
#     --rar PATH        the .rar (for multi-part, point at part1 / .rar)
#     --game-dir PATH   skip extraction, use an existing folder
#     --res WxH         target resolution        (default 1280x720)
#     --winehq          install newer Wine from WineHQ instead of Debian's
#     --no-deps         don't touch apt
#     --no-dxvk         don't install DXVK (force the OpenGL path)
#     --keep-archive    don't offer to delete the .rar afterwards
#     -h | --help
# ===========================================================================
set -Eeuo pipefail

APP_ID="hello-neighbor"
APP_NAME="Hello Neighbor"
APP_HOME="$HOME/.local/share/$APP_ID"
GAME_DIR="$APP_HOME/game"
WINEPREFIX_DIR="$APP_HOME/prefix"
BIN_DIR="$APP_HOME/bin"
DESKTOP_DIR="$HOME/.local/share/applications"
ICON_BASE="$HOME/.local/share/icons/hicolor"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARCHIVE_PATH=""
EXTRACTED_DIR=""
RES="1280x720"
USE_WINEHQ=0
WINE_UPGRADED=0
DO_DEPS=1
DO_DXVK=1
KEEP_ARCHIVE=0
LOWMEM=1           # 0 disables; trims memory use for 8 GB shared-RAM machines
SAFE_ICON=0        # --safe-icon adds a second, troubleshooting-only launcher entry
COPY_GAME=0        # with --game-dir, use the files in place; --copy duplicates
# DXVK 2.x wants Vulkan 1.3 and a few features Venus can lack; 1.10.3 is the
# compatible fallback (--dxvk-ver 1.10.3) if 2.x reports "No adapters found".
DXVK_VER="2.3.1"
DXVK_VER_EXPLICIT=0

# --- pretty output ---------------------------------------------------------
if [ -t 1 ]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
else B=""; G=""; Y=""; R=""; C=""; N=""; fi
STEP=0
step() { STEP=$((STEP+1)); printf '\n%s==> [%d/9] %s%s\n' "$B$C" "$STEP" "$1" "$N"; }
ok()   { printf '    %s*%s %s\n' "$G" "$N" "$1"; }
warn() { printf '    %s!%s %s\n' "$Y" "$N" "$1"; }
err()  { printf '    %sx%s %s\n' "$R" "$N" "$1" >&2; }
die()  { err "$1"; exit 1; }
trap 'err "Failed on line $LINENO. Nothing is half-installed that ./uninstall.sh cannot clear."' ERR

while [ $# -gt 0 ]; do
  case "$1" in
    --rar|--zip|--archive) shift; ARCHIVE_PATH="${1:-}" ;;
    --game-dir)     shift; EXTRACTED_DIR="${1:-}" ;;
    --res)          shift; RES="${1:-1280x720}" ;;
    --winehq)       USE_WINEHQ=1 ;;
    --no-deps)      DO_DEPS=0 ;;
    --no-dxvk)      DO_DXVK=0 ;;
    --keep-archive) KEEP_ARCHIVE=1 ;;
    --copy)         COPY_GAME=1 ;;
    --in-place)     COPY_GAME=0 ;;
    --safe-icon)    SAFE_ICON=1 ;;
    --lowmem)       LOWMEM=1 ;;
    --no-lowmem)    LOWMEM=0 ;;
    --dxvk-ver)     shift; DXVK_VER="${1:-2.3.1}"; DXVK_VER_EXPLICIT=1 ;;
    -h|--help)      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1  (try --help)" ;;
  esac
  shift
done

RES_W="${RES%x*}"; RES_H="${RES#*x}"

cat <<BANNER
${B}
  Hello Neighbor  ->  ChromeOS / Crostini
  ---------------------------------------${N}
  target resolution : ${RES_W}x${RES_H}
  install location  : ${APP_HOME}
BANNER

# ===========================================================================
step "Checking your system"
# ===========================================================================
[ "$(uname -m)" = "x86_64" ] || die "This needs x86_64. Detected: $(uname -m)"
ok "architecture: x86_64"

if [ -f /etc/os-release ]; then
  . /etc/os-release
  ok "distro: ${PRETTY_NAME:-unknown}"
fi

if [ -d /opt/google/cros-containers ] || grep -qi crostini /proc/cmdline 2>/dev/null \
   || [ -e /dev/wl0 ] || systemctl is-active --quiet cros-garcon.service 2>/dev/null; then
  ok "ChromeOS Crostini container detected"
  IS_CROSTINI=1
else
  warn "Doesn't look like Crostini -- continuing, but shelf integration may differ"
  IS_CROSTINI=0
fi

MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
ok "RAM visible to the container: ${MEM_MB} MB"
[ "$MEM_MB" -lt 3000 ] && warn "Under 3 GB -- close Chrome tabs before playing"

AVAIL_GB=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
ok "free disk in \$HOME: ${AVAIL_GB} GB"
[ "${AVAIL_GB:-0}" -lt 12 ] && warn "Hello Neighbor needs ~5 GB extracted plus the archive. This may be tight."

ok "CPU: $(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ //')"

# ===========================================================================
step "Installing dependencies"
# ===========================================================================
have() { command -v "$1" >/dev/null 2>&1; }

if [ "$DO_DEPS" = "1" ]; then
  echo "    (sudo may prompt for your password)"
  sudo dpkg --add-architecture i386 >/dev/null 2>&1 || true
  sudo apt-get update -qq || warn "apt update had warnings; continuing"

  PKGS=(unar p7zip-full cabextract libnotify-bin desktop-file-utils icoutils
        mesa-utils mesa-vulkan-drivers vulkan-tools xdg-utils curl)
  sudo apt-get install -y -qq "${PKGS[@]}" 2>/dev/null || warn "some optional packages were unavailable"
  ok "archive + desktop tooling installed"

  # --winehq must run even when Wine is ALREADY installed -- upgrading an
  # existing Wine 8 is the entire point of the flag. The old condition only
  # fired when no wine binary existed at all, so --winehq silently did
  # nothing on this machine.
  if [ "$USE_WINEHQ" = "1" ]; then
    WINE_BEFORE="$(wine --version 2>/dev/null || echo none)"
    ok "adding the WineHQ repository (current: $WINE_BEFORE)"
    CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")"

    # WineHQ builds are multi-arch: without i386 the 64-bit package will not
    # resolve its dependencies.
    sudo dpkg --add-architecture i386
    sudo mkdir -p /etc/apt/keyrings
    sudo curl -fsSL -o /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
      || die "could not download the WineHQ signing key -- are you online?"
    sudo curl -fsSL -o "/etc/apt/sources.list.d/winehq-$CODENAME.sources" \
      "https://dl.winehq.org/wine-builds/debian/dists/$CODENAME/winehq-$CODENAME.sources" \
      || die "could not download the WineHQ source list for $CODENAME"
    sudo apt-get update -qq || warn "apt update had warnings; continuing"

    # Debian's wine-stable conflicts with WineHQ's packages. Remove it first
    # or apt will refuse the install.
    if dpkg -l 2>/dev/null | grep -qE '^ii\s+wine(-stable)?\s'; then
      ok "removing Debian's wine packages first (they conflict with WineHQ)"
      sudo apt-get remove -y -qq wine wine64 wine32 wine-stable wine-stable-amd64 wine-stable-i386 >/dev/null 2>&1 || true
    fi

    echo "    downloading Wine (this is a few hundred MB, give it a few minutes)..."
    if sudo apt-get install -y --install-recommends winehq-staging; then
      hash -r 2>/dev/null || true
      WINE_AFTER="$(wine --version 2>/dev/null || echo unknown)"
      if [ "$WINE_AFTER" = "$WINE_BEFORE" ]; then
        warn "wine still reports $WINE_AFTER -- the upgrade did not take effect"
      else
        ok "wine upgraded: $WINE_BEFORE -> $WINE_AFTER"
        WINE_UPGRADED=1
      fi
    else
      warn "WineHQ install failed -- keeping the existing Wine"
      sudo apt-get install -y -qq wine wine64 >/dev/null 2>&1 || true
    fi
  elif ! have wine && ! have wine64; then
    sudo apt-get install -y -qq wine wine64 || die "Could not install Wine"
  fi
  ok "wine: $(wine --version 2>/dev/null || echo 'installed')"
else
  warn "--no-deps: skipping apt"
fi

have wine || have wine64 || die "Wine is not available. Re-run without --no-deps."

# ===========================================================================
step "Locating the game files"
# ===========================================================================
if [ -n "$EXTRACTED_DIR" ]; then
  [ -d "$EXTRACTED_DIR" ] || die "--game-dir '$EXTRACTED_DIR' is not a directory"
  SOURCE_DIR="$(cd "$EXTRACTED_DIR" && pwd)"
  ok "using existing folder: $SOURCE_DIR"
else
  if [ -z "$ARCHIVE_PATH" ]; then
    # be helpful: look in the obvious places. "Linux files" in the ChromeOS
    # Files app IS the container's $HOME, so that is the first place to look.
    for guess in "$HOME" "$HOME/Downloads" "/mnt/chromeos/MyFiles/Downloads" "/mnt/chromeos/MyFiles"; do
      [ -d "$guess" ] || continue
      found="$(find "$guess" -maxdepth 2 \
                 \( -iname '*.rar' -o -iname '*.zip' -o -iname '*.7z' \) \
                 -size +100M 2>/dev/null | head -1)"
      [ -n "$found" ] && { ARCHIVE_PATH="$found"; break; }
    done
    [ -n "$ARCHIVE_PATH" ] && ok "auto-detected archive: $ARCHIVE_PATH"
  fi
  [ -n "$ARCHIVE_PATH" ] || die "No archive found. Pass one with --archive /path/to/HelloNeighbor.zip"
  [ -f "$ARCHIVE_PATH" ] || die "Not a file: $ARCHIVE_PATH"
  ARCHIVE_PATH="$(cd "$(dirname "$ARCHIVE_PATH")" && pwd)/$(basename "$ARCHIVE_PATH")"
  ok "archive: $ARCHIVE_PATH ($(du -h "$ARCHIVE_PATH" | cut -f1))"

  # --- pick an extractor that understands this format ----------------------
  # Note: Debian's unrar-free CANNOT read RAR5 and fails with a confusing
  # error, so it is deliberately last. For .zip we prefer unzip, but fall
  # back to 7z/unar because some large game zips use ZIP64 or deflate64,
  # which older unzip builds choke on.
  shopt -s nocasematch
  case "$ARCHIVE_PATH" in
    *.zip) FMT="zip" ;;
    *.7z)  FMT="7z"  ;;
    *)     FMT="rar" ;;
  esac
  shopt -u nocasematch

  EXTRACT_CMD=""
  if [ "$FMT" = "zip" ]; then
    if   have unzip; then EXTRACT_CMD="unzip"
    elif have 7zz;   then EXTRACT_CMD="7zz"
    elif have 7z;    then EXTRACT_CMD="7z"
    elif have unar;  then EXTRACT_CMD="unar"
    else die "No zip extractor. Install one with: sudo apt install unzip"; fi
  else
    if   have unar;       then EXTRACT_CMD="unar"
    elif have 7zz;        then EXTRACT_CMD="7zz"
    elif have 7z;         then EXTRACT_CMD="7z"
    elif have unrar;      then EXTRACT_CMD="unrar"
    elif have unrar-free; then EXTRACT_CMD="unrar-free"
    else die "No RAR extractor. Install one with: sudo apt install unar"; fi
  fi
  ok "format: $FMT   extractor: $EXTRACT_CMD"

  STAGE="$APP_HOME/.extract"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  echo "    extracting (several minutes for a few GB -- grab a drink)..."
  case "$EXTRACT_CMD" in
    unzip)      unzip -q -o "$ARCHIVE_PATH" -d "$STAGE" ;;
    unar)       unar -quiet -force-overwrite -output-directory "$STAGE" "$ARCHIVE_PATH" ;;
    7zz|7z)     "$EXTRACT_CMD" x -y -bso0 -bsp1 -o"$STAGE" "$ARCHIVE_PATH" ;;
    unrar)      unrar x -y -idq "$ARCHIVE_PATH" "$STAGE/" ;;
    unrar-free) unrar-free -x "$ARCHIVE_PATH" "$STAGE/" ;;
  esac
  ok "extraction finished"
  SOURCE_DIR="$STAGE"
fi

# ===========================================================================
step "Identifying the build"
# ===========================================================================
SHIP_EXE="$(find "$SOURCE_DIR" -maxdepth 7 -type f -iname 'HelloNeighbor-Win64-Shipping.exe' 2>/dev/null | head -1)"
[ -z "$SHIP_EXE" ] && SHIP_EXE="$(find "$SOURCE_DIR" -maxdepth 7 -type f -iname 'HelloNeighbor-Win32-Shipping.exe' 2>/dev/null | head -1)"
STUB_EXE="$(find "$SOURCE_DIR" -maxdepth 4 -type f -iname 'HelloNeighbor.exe' 2>/dev/null | head -1)"

if [ -n "$SHIP_EXE" ]; then
  GAME_ROOT="$(cd "$(dirname "$SHIP_EXE")/../../.." && pwd)"
elif [ -n "$STUB_EXE" ]; then
  GAME_ROOT="$(dirname "$STUB_EXE")"
else
  err "Could not find HelloNeighbor.exe anywhere under:"
  err "  $SOURCE_DIR"
  echo "    Top-level contents were:"
  find "$SOURCE_DIR" -maxdepth 2 | head -40 | sed 's/^/      /'
  die "Unrecognised archive layout -- send me the output above."
fi
ok "game root: $GAME_ROOT"
[ -n "$SHIP_EXE" ] && ok "shipping exe: $(basename "$SHIP_EXE")"

PAKS="$(find "$GAME_ROOT" -maxdepth 5 -type d -iname 'Paks' 2>/dev/null | head -1)"
if [ -n "$PAKS" ]; then
  ok "paks: $(ls -1 "$PAKS"/*.pak 2>/dev/null | wc -l) file(s), $(du -sh "$PAKS" 2>/dev/null | cut -f1)"
fi
UE_VER="$(find "$GAME_ROOT" -maxdepth 4 -iname '*.version' -o -maxdepth 4 -iname 'build.version' 2>/dev/null | head -1)"
[ -n "$UE_VER" ] && ok "version file: $(basename "$UE_VER")"

# --- put the game where the launcher expects it ----------------------------
# Three cases:
#   * we extracted it ourselves  -> move out of staging (instant, same fs)
#   * --game-dir, default        -> use IN PLACE, no copy. A 5 GB game does
#                                   not need duplicating just to add a
#                                   launcher; a symlink is enough.
#   * --game-dir --copy          -> duplicate it (needs 2x the disk)
mkdir -p "$APP_HOME"
if [ "$GAME_ROOT" = "$GAME_DIR" ]; then
  : # already in place
elif [ -n "${STAGE:-}" ] && [[ "$GAME_ROOT" == "$STAGE"* ]]; then
  rm -rf "$GAME_DIR"
  mv "$GAME_ROOT" "$GAME_DIR"            # same filesystem: instant
  rm -rf "$STAGE"
elif [ "$COPY_GAME" = "1" ]; then
  NEED_KB=$(du -sk "$GAME_ROOT" | cut -f1)
  FREE_KB=$(df -Pk "$APP_HOME" | tail -1 | awk '{print $4}')
  if [ "$FREE_KB" -lt "$NEED_KB" ]; then
    die "--copy needs $((NEED_KB/1024/1024)) GB but only $((FREE_KB/1024/1024)) GB is free. Drop --copy to use the files in place."
  fi
  rm -rf "$GAME_DIR"
  echo "    copying game files into $GAME_DIR ..."
  cp -a "$GAME_ROOT" "$GAME_DIR"
else
  # in-place: symlink so the launcher's paths stay identical either way
  rm -rf "$GAME_DIR"
  ln -s "$GAME_ROOT" "$GAME_DIR"
  ok "using the game in place (no copy) -- saved $(du -sh "$GAME_ROOT" 2>/dev/null | cut -f1) of disk"
fi
ok "game ready at $GAME_DIR ($(du -shL "$GAME_DIR" 2>/dev/null | cut -f1))"

FINAL_EXE="$(find -L "$GAME_DIR" -maxdepth 7 -type f -iname 'HelloNeighbor-Win*-Shipping.exe' | head -1)"
[ -z "$FINAL_EXE" ] && FINAL_EXE="$(find -L "$GAME_DIR" -maxdepth 4 -type f -iname 'HelloNeighbor.exe' | head -1)"

# ===========================================================================
step "Creating the Wine prefix"
# ===========================================================================
export WINEPREFIX="$WINEPREFIX_DIR"
export WINEARCH=win64
export WINEDEBUG=-all
export WINEDLLOVERRIDES="mscoree,mshtml="
mkdir -p "$WINEPREFIX"
if [ ! -d "$WINEPREFIX/drive_c" ]; then
  echo "    bootstrapping (ignore any mono/gecko prompts -- they're suppressed)..."
  wineboot -u >/dev/null 2>&1 || true
  wineserver -w 2>/dev/null || true
elif [ "$WINE_UPGRADED" = "1" ]; then
  # The prefix was built by the previous Wine. Its bundled DLLs and registry
  # need updating to match the new one, or the game loads a mix of both.
  echo "    updating the existing prefix for the new Wine version..."
  wineboot -u >/dev/null 2>&1 || true
  wineserver -w 2>/dev/null || true
  ok "prefix updated"
fi
ok "prefix ready: $WINEPREFIX"

# Hello Neighbor is a UE4 title: it wants the VC++ runtime. Wine ships
# usable built-in replacements, so we only override if winetricks exists.
if have winetricks; then
  winetricks -q vcrun2017 >/dev/null 2>&1 && ok "vcrun2017 installed" || warn "vcrun2017 skipped (built-in should work)"
fi

# ===========================================================================
step "Setting up graphics (DXVK / OpenGL)"
# ===========================================================================
VULKAN_OK=0
if [ -n "$(ls -A /usr/share/vulkan/icd.d/*.json 2>/dev/null)" ]; then
  if timeout 20 vulkaninfo --summary >/dev/null 2>&1; then VULKAN_OK=1; fi
fi

if [ "$VULKAN_OK" = "1" ]; then
  ok "Vulkan is available (Venus passthrough working)"
else
  warn "No usable Vulkan -- falling back to the OpenGL/VirGL path (WineD3D)"
  warn "UE4 titles crash on WineD3D here (GL_RGBA8_SNORM buffer views)."
  warn "Run ./tools/enable-vulkan.sh to install the Venus driver, then re-run this."
  DO_DXVK=0
fi

# --- match DXVK to the Wine we have ----------------------------------------
# DXVK 2.x drives modern Vulkan entry points. Wine's winevulkan is a
# generated thunk layer: call something the installed Wine was not built to
# forward and the unix call returns an error, which trips
#   Assertion failed! File: dlls/winevulkan/loader_thunks.c  Expression: !status
# and kills the process before the game draws anything. Debian 12 ships
# Wine 8.0 (January 2023), which predates the surface/swapchain
# maintenance extensions that Mesa 25 advertises and DXVK 2.x will happily
# use. DXVK 1.10.x sticks to Vulkan 1.1 and stays inside what Wine 8 knows.
if [ "$DO_DXVK" = "1" ]; then
  WINE_VER_STR="$(wine --version 2>/dev/null | sed 's/^wine-//' | awk '{print $1}')"
  WINE_MAJOR="${WINE_VER_STR%%.*}"
  case "$WINE_MAJOR" in (*[!0-9]*|'') WINE_MAJOR=0 ;; esac
  if [ "$WINE_MAJOR" -gt 0 ] && [ "$WINE_MAJOR" -lt 9 ] \
     && [ "$DXVK_VER_EXPLICIT" = "0" ] && [ "${DXVK_VER%%.*}" -ge 2 ]; then
    warn "Wine $WINE_VER_STR is older than 9.0 -- too old for DXVK ${DXVK_VER}"
    warn "using DXVK 1.10.3 instead (override with --dxvk-ver)"
    warn "for the newest stack instead, re-run with --winehq"
    DXVK_VER="1.10.3"
  fi
fi

if [ "$DO_DXVK" = "1" ]; then
  TMPD="$(mktemp -d)"
  if curl -fsSL -o "$TMPD/dxvk.tar.gz" \
      "https://github.com/doitsujin/dxvk/releases/download/v${DXVK_VER}/dxvk-${DXVK_VER}.tar.gz" 2>/dev/null; then
    tar -xzf "$TMPD/dxvk.tar.gz" -C "$TMPD"
    SYS32="$WINEPREFIX/drive_c/windows/system32"
    if [ ! -d "$SYS32" ]; then
      warn "Wine prefix looks incomplete ($SYS32 missing) -- skipping DXVK"
      DO_DXVK=0
    fi
  else
    warn "could not download DXVK $DXVK_VER -- staying on WineD3D"
    DO_DXVK=0
  fi
  if [ "$DO_DXVK" = "1" ]; then
    # DXVK 2.x no longer ships d3d10core.dll. Only override a DLL we actually
    # copied -- pointing Wine at a "native" DLL that is not there makes the
    # loader fail outright instead of falling back to the builtin.
    COPIED=""
    for dll in d3d11 dxgi d3d10core d3d9; do
      src="$TMPD/dxvk-${DXVK_VER}/x64/${dll}.dll"
      if [ -f "$src" ]; then
        cp -f "$src" "$SYS32/${dll}.dll"
        COPIED="${COPIED:+$COPIED }$dll"
      fi
    done
    if [ -n "$COPIED" ]; then
      for dll in $COPIED; do
        wine reg add 'HKCU\Software\Wine\DllOverrides' /v "$dll" /d native /f >/dev/null 2>&1 || true
      done
      touch "$WINEPREFIX/.dxvk-installed"
      ok "DXVK $DXVK_VER installed -> DirectX 11 runs on Vulkan"
      ok "overrode: $COPIED"
    else
      warn "DXVK archive had no x64 DLLs -- staying on WineD3D"
      DO_DXVK=0
    fi
  fi
  if [ "$DO_DXVK" = "1" ] && [ ! -f "$WINEPREFIX/.dxvk-installed" ]; then
    warn "DXVK could not be set up -- falling back to WineD3D"
    DO_DXVK=0
  fi
  rm -rf "$TMPD"
fi

if [ "$DO_DXVK" = "0" ] && [ -f "$WINEPREFIX/.dxvk-installed" ]; then
  # A previous run installed DXVK. Undo it properly, otherwise the launcher
  # keeps selecting the DXVK backend and loads half-removed DLLs.
  SYS32="$WINEPREFIX/drive_c/windows/system32"
  for dll in d3d11 dxgi d3d10core d3d9; do
    rm -f "$SYS32/${dll}.dll"
    wine reg add 'HKCU\Software\Wine\DllOverrides' /v "$dll" /d builtin /f >/dev/null 2>&1 || true
  done
  rm -f "$WINEPREFIX/.dxvk-installed"
  wineboot -u >/dev/null 2>&1 || true
  ok "removed the previous DXVK install -- back on WineD3D"
fi

# Decide the low-memory profile here, before anything that depends on it.
# The container sees roughly 6.5 GB of this machine's 8 GB, shared with
# ChromeOS, and the game is 4.9 GB.
CONTAINER_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 8192)
LOWMEM_APPLIED=0
if [ "$LOWMEM" = "1" ] && [ "$CONTAINER_MB" -lt 9000 ]; then LOWMEM_APPLIED=1; fi
DXVK_MEM_MB=2048
[ "$LOWMEM_APPLIED" = "1" ] && DXVK_MEM_MB=1024
cat > "$APP_HOME/dxvk.conf" <<DXVKCONF
# Report a generous VRAM figure: UE4 sizes its streaming pool from this and
# an iGPU honestly reporting 256 MB makes the game thrash textures.
dxgi.maxDeviceMemory = ${DXVK_MEM_MB}
dxgi.maxSharedMemory = ${DXVK_MEM_MB}
d3d11.maxFeatureLevel = 11_0
dxvk.enableStateCache = True
dxvk.numCompilerThreads = 2
d3d11.cachedDynamicResources = cr

# UE4 4.20 creates its swap chain while the game window is still being set
# up. Under Crostini's X server (sommelier) the window often is not ready to
# back a Vulkan surface at that instant, so vkCreateSwapchainKHR fails and
# UE4 dies with:
#   D3DRHI->GetFactory()->CreateSwapChain(...) failed ... with error E_FAIL
# deferSurfaceCreation delays the real Vulkan surface until the first
# Present, by which point the window exists. This is DXVK's standard
# workaround for exactly this failure.
#
# DISABLED on 2026-10-21. That failure was a Wine 8 problem. Measured on the
# reference Chromebook under Wine 11.10 + DXVK 2.3.1 with tools/try-fixes.sh:
# with this setting ON the game died almost immediately, and with it OFF the
# game reached the tinyBuild loading screen. Deferring the surface had become
# the cause rather than the cure. Re-enable with:
#   ./tools/try-fixes.sh --only 3
# dxgi.deferSurfaceCreation = True

# Never let the game ask for a real display mode change: meaningless in a
# Crostini window and another source of swap-chain failures.
dxgi.maxFrameLatency = 1

# Venus's queued (FIFO/vsync) present path is the one that misbehaves under
# ChromeOS's compositor. ChromeOS does its own compositing and pacing
# anyway, so there is nothing to gain by waiting on it here.
dxgi.syncInterval = 0
DXVKCONF
ok "dxvk.conf written"

# ===========================================================================
step "Applying the optimised UE4 configuration"
# ===========================================================================
# pipefail is on: if the prefix has no users directory, grep finds nothing,
# returns 1, and the whole installer aborts here with an opaque line number
# instead of falling back to $USER. Swallow it.
WINUSER="$(ls "$WINEPREFIX/drive_c/users" 2>/dev/null | grep -v -e '^Public$' -e '^crossover$' | head -1 || true)"
WINUSER="${WINUSER:-${USER:-$(id -un)}}"
CFG_DST="$WINEPREFIX/drive_c/users/$WINUSER/AppData/Local/HelloNeighbor/Saved/Config/WindowsNoEditor"
mkdir -p "$CFG_DST"

for f in Engine.ini Scalability.ini GameUserSettings.ini Input.ini; do
  if [ -f "$SRC_DIR/config/$f" ]; then
    [ -f "$CFG_DST/$f" ] && cp -f "$CFG_DST/$f" "$CFG_DST/$f.bak-$(date +%s)"
    # Word-boundary swap: verified that 1280/720 appear ONLY as resolution
    # values in these files, so this cannot clobber an unrelated setting.
    # NOTE the ordering: the "1280x720" form must be handled BEFORE the
    # word-boundary rules, because \b does not match between "1280" and "x"
    # ('x' is a word character) so r.SetRes would otherwise be skipped.
    sed -E -e "s/1280x720/${RES_W}x${RES_H}/g" \
           -e "s/\b1280\b/${RES_W}/g" \
           -e "s/\b720\b/${RES_H}/g" \
        "$SRC_DIR/config/$f" > "$CFG_DST/$f"
    ok "$f"
  fi
done

# --- low-memory trim -------------------------------------------------------
# This Chromebook has 8 GB shared with ChromeOS, of which the container sees
# about 6.5 GB, and the game is 4.9 GB. Loading the first real level is the
# heaviest moment of the run: UE4 fills its texture streaming pool while
# DXVK allocates its own. Overcommit here and the process is killed with no
# error message at all, which looks exactly like a crash.
if [ "$LOWMEM_APPLIED" = "1" ]; then
  if true; then
    sed -i -E 's/^r\.Streaming\.PoolSize=.*/r.Streaming.PoolSize=512/' "$CFG_DST/Engine.ini" 2>/dev/null || true
    sed -i -E 's/^r\.Streaming\.MaxTempMemoryAllowed=.*/r.Streaming.MaxTempMemoryAllowed=48/' "$CFG_DST/Engine.ini" 2>/dev/null || true
    # Stop the quality presets from putting the big pool back.
    sed -i -E 's/^r\.Streaming\.PoolSize=1024/r.Streaming.PoolSize=512/; s/^r\.Streaming\.PoolSize=1500/r.Streaming.PoolSize=700/' \
        "$CFG_DST/Scalability.ini" 2>/dev/null || true
    ok "low-memory profile applied (${CONTAINER_MB} MB visible): streaming pool 512 MB"
  fi
fi

# UE4 rewrites these on exit unless they are read-only; lock the two that the
# options menu likes to stomp.
chmod u+w "$CFG_DST"/*.ini 2>/dev/null || true
ok "config written to AppData/Local/HelloNeighbor/Saved/Config/WindowsNoEditor"

# ===========================================================================
step "Installing the launcher, icon and shelf entry"
# ===========================================================================
mkdir -p "$BIN_DIR" "$DESKTOP_DIR"
install -m 0755 "$SRC_DIR/launcher/hello-neighbor-launch.sh" "$BIN_DIR/hello-neighbor-launch"
ok "launch wrapper -> $BIN_DIR/hello-neighbor-launch"

cat > "$APP_HOME/launcher.conf" <<CONF
# Hello Neighbor launcher settings -- edit freely, no reinstall needed.
RES_W=$RES_W
RES_H=$RES_H
FORCE_BACKEND=""     # "" (auto) | dxvk | wined3d
# Windowed, deliberately. Unreal's own crash report showed this build
# forcing exclusive fullscreen and DXGI refusing it:
#   CreateSwapChain(...) failed at WindowsD3D11Viewport.cpp:126 with E_FAIL
# DXVK confirmed it with "Exclusive FS: 1" and a 1920x1080 back buffer, i.e.
# the -ResX/-ResY arguments were being ignored. A real display mode change
# has no meaning inside Crostini. Windowed also makes the software present
# path 2.25x cheaper at 1280x720 than at 1920x1080.
WINDOWED=1
ENABLE_CONSOLE=1
EXTRA_GAME_ARGS=""

# --- THE fix for "it starts, then vanishes after ~15 seconds" -------------
# Not a Wine problem. tinyBuild document it themselves in "[PC] The game
# crashes at start": on 10th-gen Intel CPUs and newer, set the environment
# variable OPENSSL_ia32cap to :~0x20000000. The game bundles an old OpenSSL
# that mis-detects the SHA-NI instructions those CPUs introduced, runs a
# code path it was not built for, corrupts memory and dies with 0xC0000005
# before Unreal's crash handler exists -- hence no crash report, and hence
# the identical failure on every graphics driver, including a software one.
# The launcher sets it for you. 0 disables it (for testing only).
OPENSSL_FIX=1

# --- if the game crashes while showing a frame --------------------------
# Venus (Crostini's Vulkan driver) has a known bug presenting frames through
# ChromeOS's X server. The symptom is UE4 dying in D3D11Viewport.cpp with
# error 887A0020 (DXGI_ERROR_DRIVER_INTERNAL_ERROR) after a few seconds.
# 1 moves only the final "copy the frame into the window" step to the CPU.
# All rendering stays on the GPU, so the cost is small.
# auto = on inside Crostini, which is what this machine needs.
HN_VK_WSI_SW=auto

# Run inside a single Wine-owned window. Helps when ChromeOS's window
# handling confuses the game.
VDESK=0
CONF
ok "launcher.conf written (tweak resolution here later)"

# --- icons -----------------------------------------------------------------
if [ -f "$SRC_DIR/launcher/$APP_ID.png" ]; then
  for sz in 16 24 32 48 64 128 256 512; do
    d="$ICON_BASE/${sz}x${sz}/apps"; mkdir -p "$d"
    if have convert; then
      convert "$SRC_DIR/launcher/$APP_ID.png" -resize "${sz}x${sz}" "$d/$APP_ID.png" 2>/dev/null \
        || cp -f "$SRC_DIR/launcher/$APP_ID.png" "$d/$APP_ID.png"
    else
      cp -f "$SRC_DIR/launcher/$APP_ID.png" "$d/$APP_ID.png"
    fi
  done
  mkdir -p "$HOME/.local/share/pixmaps"
  cp -f "$SRC_DIR/launcher/$APP_ID.png" "$HOME/.local/share/pixmaps/$APP_ID.png"
  ok "icon installed at 8 sizes"
fi

# The bundled icon is a stand-in. The game's own executable carries the real
# artwork, which looks far better in the launcher -- use it when we can.
if [ -x "$SRC_DIR/tools/extract-icon.sh" ]; then
  "$SRC_DIR/tools/extract-icon.sh" --game-dir "$GAME_DIR" 2>&1 | sed 's/^/  /' || true
fi

# --- .desktop --------------------------------------------------------------
cat > "$DESKTOP_DIR/$APP_ID.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Version=1.0
Name=Hello Neighbor
GenericName=Stealth Horror Game
Comment=Sneak into your neighbour's house and find out what he's hiding
Exec=$BIN_DIR/hello-neighbor-launch
Icon=$APP_ID
Terminal=false
Categories=Game;ActionGame;AdventureGame;
Keywords=hello;neighbor;neighbour;horror;stealth;tinybuild;
StartupNotify=true
StartupWMClass=helloneighbor-win64-shipping.exe
PrefersNonDefaultGPU=true
Actions=Windowed;SafeMode;Kill;Logs;

[Desktop Action Windowed]
Name=Play in a window
Exec=$BIN_DIR/hello-neighbor-launch --windowed

[Desktop Action SafeMode]
Name=Safe mode (OpenGL / DX10)
Exec=$BIN_DIR/hello-neighbor-launch --safe --windowed

[Desktop Action Kill]
Name=Force quit the game
Exec=$BIN_DIR/hello-neighbor-launch --kill

[Desktop Action Logs]
Name=Open the log folder
Exec=xdg-open $APP_HOME/logs
DESKTOP

chmod 0644 "$DESKTOP_DIR/$APP_ID.desktop"
ok ".desktop -> $DESKTOP_DIR/$APP_ID.desktop"

# ChromeOS's shelf/launcher does NOT surface Desktop Actions the way GNOME
# does, so the right-click fallbacks above are invisible there. Safe Mode
# therefore has to be its own launcher entry -- but two near-identical
# "Hello Neighbor" icons in the launcher is confusing, so it is opt-in.
# Safe Mode forces the OpenGL/WineD3D path, which crashes this UE4 build
# outright, so it is only worth having while debugging.
if [ "$SAFE_ICON" = "1" ]; then
  cat > "$DESKTOP_DIR/$APP_ID-safe.desktop" <<DESKTOPSAFE
[Desktop Entry]
Type=Application
Version=1.0
Name=Hello Neighbor (Safe Mode)
GenericName=Stealth Horror Game
Comment=Hello Neighbor in a small window on the OpenGL path, for troubleshooting
Exec=$BIN_DIR/hello-neighbor-launch --safe --windowed
Icon=$APP_ID
Terminal=false
Categories=Game;ActionGame;AdventureGame;
Keywords=hello;neighbor;safe;troubleshoot;
StartupNotify=true
StartupWMClass=helloneighbor-win64-shipping.exe
NoDisplay=false
DESKTOPSAFE
  chmod 0644 "$DESKTOP_DIR/$APP_ID-safe.desktop"
  ok ".desktop (safe mode) -> $DESKTOP_DIR/$APP_ID-safe.desktop"
elif [ -f "$DESKTOP_DIR/$APP_ID-safe.desktop" ]; then
  rm -f "$DESKTOP_DIR/$APP_ID-safe.desktop"
  ok "removed the duplicate Safe Mode icon (re-add with --safe-icon)"
fi

if have desktop-file-validate; then
  desktop-file-validate "$DESKTOP_DIR/$APP_ID.desktop" && ok ".desktop validates clean" \
    || warn ".desktop has validation warnings (usually harmless)"
fi
have update-desktop-database && update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
have gtk-update-icon-cache && gtk-update-icon-cache -f -t "$ICON_BASE" 2>/dev/null || true

# ===========================================================================
step "Finishing up"
# ===========================================================================
export HN_GAME_EXE="$FINAL_EXE"
sed -i "s|^#\?HN_GAME_EXE=.*|HN_GAME_EXE=\"$FINAL_EXE\"|" "$APP_HOME/launcher.conf" 2>/dev/null || \
  echo "HN_GAME_EXE=\"$FINAL_EXE\"" >> "$APP_HOME/launcher.conf"

if [ -z "$EXTRACTED_DIR" ] && [ "$KEEP_ARCHIVE" = "0" ] && [ -n "$ARCHIVE_PATH" ]; then
  echo
  read -r -p "    Delete the original archive to reclaim $(du -h "$ARCHIVE_PATH" | cut -f1)? [y/N] " yn
  case "$yn" in [Yy]*) rm -f "$ARCHIVE_PATH"; ok "archive deleted" ;; *) ok "archive kept" ;; esac
fi

if [ "$SAFE_ICON" = "1" ]; then
  SAFE_ICON_NOTE="  A second icon, ${B}Hello Neighbor (Safe Mode)${N}, is installed for
  troubleshooting. It forces the OpenGL path, which this build crashes on,
  so it is only useful for comparison. Remove it by re-running without
  --safe-icon."
else
  SAFE_ICON_NOTE="  Only one icon is installed. If the game will not start, see
  ${C}$APP_HOME/logs/${N} -- the launcher writes a plain-English diagnosis
  there when it recognises the failure."
fi

cat <<DONE

${G}${B}  Done.${N}

  ${B}Hello Neighbor${N} is now in your ChromeOS launcher. Press the Search/
  Everything key, type "Hello", and it's there. Right-click it and pick
  ${B}Pin to shelf${N} and you never have to open a terminal again.

${SAFE_ICON_NOTE}

  First launch compiles shaders, so it will be slower and may sit on a
  black screen for up to a minute. That is normal and happens once.

  Resolution and other knobs:   ${C}$APP_HOME/launcher.conf${N}
  Logs if anything misbehaves:  ${C}$APP_HOME/logs/${N}
  Remove everything:            ${C}$SRC_DIR/uninstall.sh${N}

DONE
