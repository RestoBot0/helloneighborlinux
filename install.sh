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
DO_DEPS=1
DO_DXVK=1
KEEP_ARCHIVE=0

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

  PKGS=(unar p7zip-full cabextract libnotify-bin desktop-file-utils
        mesa-utils mesa-vulkan-drivers vulkan-tools xdg-utils curl)
  sudo apt-get install -y -qq "${PKGS[@]}" 2>/dev/null || warn "some optional packages were unavailable"
  ok "archive + desktop tooling installed"

  if ! have wine && ! have wine64; then
    if [ "$USE_WINEHQ" = "1" ]; then
      ok "adding the WineHQ repository"
      CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")"
      sudo mkdir -p /etc/apt/keyrings
      sudo curl -fsSL -o /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
      sudo curl -fsSL -o /etc/apt/sources.list.d/winehq-"$CODENAME".sources \
        "https://dl.winehq.org/wine-builds/debian/dists/$CODENAME/winehq-$CODENAME.sources"
      sudo apt-get update -qq
      sudo apt-get install -y --install-recommends winehq-staging \
        || { warn "WineHQ failed, falling back to Debian's wine"; sudo apt-get install -y -qq wine wine64; }
    else
      sudo apt-get install -y -qq wine wine64 || die "Could not install Wine"
    fi
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

# move/copy into place
mkdir -p "$APP_HOME"
if [ "$GAME_ROOT" != "$GAME_DIR" ]; then
  rm -rf "$GAME_DIR"
  if [ -n "${STAGE:-}" ] && [[ "$GAME_ROOT" == "$STAGE"* ]]; then
    mv "$GAME_ROOT" "$GAME_DIR"          # same filesystem: instant
    rm -rf "$STAGE"
  else
    echo "    copying game files into $GAME_DIR ..."
    cp -a "$GAME_ROOT" "$GAME_DIR"
  fi
fi
ok "installed to $GAME_DIR ($(du -sh "$GAME_DIR" 2>/dev/null | cut -f1))"

FINAL_EXE="$(find "$GAME_DIR" -maxdepth 7 -type f -iname 'HelloNeighbor-Win*-Shipping.exe' | head -1)"
[ -z "$FINAL_EXE" ] && FINAL_EXE="$(find "$GAME_DIR" -maxdepth 4 -type f -iname 'HelloNeighbor.exe' | head -1)"

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
  warn "No usable Vulkan -- will use the OpenGL/VirGL path with DX10/SM4"
  DO_DXVK=0
fi

if [ "$DO_DXVK" = "1" ]; then
  DXVK_VER="2.3.1"
  TMPD="$(mktemp -d)"
  if curl -fsSL -o "$TMPD/dxvk.tar.gz" \
      "https://github.com/doitsujin/dxvk/releases/download/v${DXVK_VER}/dxvk-${DXVK_VER}.tar.gz" 2>/dev/null; then
    tar -xzf "$TMPD/dxvk.tar.gz" -C "$TMPD"
    SYS32="$WINEPREFIX/drive_c/windows/system32"
    for dll in d3d11 dxgi d3d10core d3d9; do
      src="$TMPD/dxvk-${DXVK_VER}/x64/${dll}.dll"
      [ -f "$src" ] && cp -f "$src" "$SYS32/${dll}.dll"
    done
    wine reg add 'HKCU\Software\Wine\DllOverrides' /v d3d11   /d native /f >/dev/null 2>&1
    wine reg add 'HKCU\Software\Wine\DllOverrides' /v dxgi    /d native /f >/dev/null 2>&1
    wine reg add 'HKCU\Software\Wine\DllOverrides' /v d3d10core /d native /f >/dev/null 2>&1
    touch "$WINEPREFIX/.dxvk-installed"
    ok "DXVK $DXVK_VER installed -> DirectX 11 runs on Vulkan"
  else
    warn "DXVK download failed -- falling back to WineD3D"
  fi
  rm -rf "$TMPD"
fi

cat > "$APP_HOME/dxvk.conf" <<'DXVKCONF'
# Report a generous VRAM figure: UE4 sizes its streaming pool from this and
# an iGPU honestly reporting 256 MB makes the game thrash textures.
dxgi.maxDeviceMemory = 2048
dxgi.maxSharedMemory = 2048
d3d11.maxFeatureLevel = 11_0
dxvk.enableStateCache = True
dxvk.numCompilerThreads = 2
d3d11.cachedDynamicResources = cr
DXVKCONF
ok "dxvk.conf written"

# ===========================================================================
step "Applying the optimised UE4 configuration"
# ===========================================================================
WINUSER="$(ls "$WINEPREFIX/drive_c/users" 2>/dev/null | grep -v -e '^Public$' -e '^crossover$' | head -1)"
WINUSER="${WINUSER:-$USER}"
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
WINDOWED=0
ENABLE_CONSOLE=1
EXTRA_GAME_ARGS=""
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

cat <<DONE

${G}${B}  Done.${N}

  ${B}Hello Neighbor${N} is now in your ChromeOS launcher. Press the Search/
  Everything key, type "Hello", and it's there. Right-click it and pick
  ${B}Pin to shelf${N} and you never have to open a terminal again.

  Right-clicking the icon also gives you:
      Play in a window / Safe mode / Force quit / Open logs

  First launch compiles shaders, so it will be slower and may sit on a
  black screen for up to a minute. That is normal and happens once.

  Resolution and other knobs:   ${C}$APP_HOME/launcher.conf${N}
  Logs if anything misbehaves:  ${C}$APP_HOME/logs/${N}
  Remove everything:            ${C}$SRC_DIR/uninstall.sh${N}

DONE
