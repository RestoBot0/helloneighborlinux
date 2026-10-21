#!/usr/bin/env bash
# ===========================================================================
#  install-mod.sh -- put a downloaded Hello Neighbor mod where the game
#                    will actually find it, and say so if it never will.
#
#  Hello Neighbor loads mods the way Unreal Engine 4 loads plugins. The game
#  scans HelloNeighbor/Mods/, and for each sub-folder it looks for a
#  .uplugin descriptor. Finding one, it mounts the .pak packed inside that
#  folder and lists the mod in the in-game MODDING menu:
#
#      HelloNeighbor/Mods/
#        MyMod/
#          MyMod.uplugin                 <- descriptor, names the mod
#          Content/Paks/.../MyMod.pak    <- the actual content
#
#  Three things stop a perfectly good mod from appearing, and all three are
#  handled here:
#
#    1. The folder name must match the .uplugin file name exactly. Downloads
#       routinely arrive as "TheNeighborsComeback2" holding
#       "TheNeighborsComeback.uplugin", and the game shows nothing at all.
#    2. Spaces in the folder name break it too.
#    3. A mod with no .pak -- just loose .uasset files -- is a Mod Kit mod.
#       It cannot run in the retail game at any price; it needs the ~25 GB
#       Hello Neighbor Mod Kit from the Epic launcher.
#
#  Usage:
#    ./tools/install-mod.sh <file.zip | file.rar | folder>
#    ./tools/install-mod.sh --list
#    ./tools/install-mod.sh --remove <ModName>
#    ./tools/install-mod.sh --check <file.zip | folder>   (inspect, install nothing)
# ===========================================================================
set -Eeuo pipefail

APP_ID="hello-neighbor"
APP_HOME="$HOME/.local/share/$APP_ID"
GAME_DIR="${HN_GAME_DIR:-$APP_HOME/game}"
ACTION="install"
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --list)     ACTION="list" ;;
    --remove)   ACTION="remove"; shift; TARGET="${1:-}" ;;
    --check)    ACTION="check";  shift; TARGET="${1:-}" ;;
    --game-dir) shift; GAME_DIR="${1:-$GAME_DIR}" ;;
    -h|--help)  sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "Unknown option: $1" >&2; exit 1 ;;
    *)          TARGET="$1" ;;
  esac
  shift
done

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
else B=""; G=""; Y=""; R=""; C=""; N=""; fi
hdr()  { printf '\n%s==> %s%s\n' "$B$C" "$1" "$N"; }
ok()   { printf '    %s*%s %s\n' "$G" "$N" "$1"; }
warn() { printf '    %s!%s %s\n' "$Y" "$N" "$1"; }
err()  { printf '    %sx%s %s\n' "$R" "$N" "$1" >&2; }
die()  { err "$1"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- where the Mods folder lives --------------------------------------------
# -L throughout: an --in-place install makes $APP_HOME/game a symlink to the
# real game folder, and plain find/test would walk straight past it.
[ -d "$GAME_DIR" ] || die "game folder not found: $GAME_DIR  (run ./install.sh first)"
INNER="$(find -L "$GAME_DIR" -maxdepth 1 -type d -iname 'HelloNeighbor' 2>/dev/null | head -1)"
[ -n "$INNER" ] || die "no HelloNeighbor/ folder inside $GAME_DIR -- is that the game root?"
MODS_DIR="$INNER/Mods"

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------
if [ "$ACTION" = "list" ]; then
  hdr "Mods installed in $MODS_DIR"
  if [ ! -d "$MODS_DIR" ]; then echo "    (no Mods folder yet)"; exit 0; fi
  found=0
  for d in "$MODS_DIR"/*/; do
    [ -d "$d" ] || continue
    found=1
    name="$(basename "$d")"
    up="$(find -L "$d" -maxdepth 1 -name '*.uplugin' 2>/dev/null | head -1)"
    pak="$(find -L "$d" -name '*.pak' 2>/dev/null | head -1)"
    note=""
    if [ -z "$up" ];  then note="${note} [no .uplugin]"; fi
    if [ -z "$pak" ]; then note="${note} [no .pak -- Mod Kit only]"; fi
    if [ -n "$up" ] && [ "$(basename "$up" .uplugin)" != "$name" ]; then
      note="${note} [name mismatch: expected $(basename "$up" .uplugin)]"
    fi
    if [ -n "$note" ]; then warn "$name$note"; else ok "$name"; fi
  done
  # a bare .pak dropped straight into Mods/ is the other accepted shape
  for f in "$MODS_DIR"/*.pak; do
    [ -f "$f" ] || continue
    found=1; ok "$(basename "$f")  (loose .pak)"
  done
  [ "$found" = "1" ] || echo "    (empty)"
  exit 0
fi

# ---------------------------------------------------------------------------
# remove
# ---------------------------------------------------------------------------
if [ "$ACTION" = "remove" ]; then
  [ -n "$TARGET" ] || die "--remove needs a mod name (see --list)"
  if [ -d "$MODS_DIR/$TARGET" ]; then
    rm -rf "${MODS_DIR:?}/$TARGET"; ok "removed $TARGET"
  elif [ -f "$MODS_DIR/$TARGET" ]; then
    rm -f "$MODS_DIR/$TARGET"; ok "removed $TARGET"
  else
    die "no such mod: $TARGET  (see --list)"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# install / check
# ---------------------------------------------------------------------------
[ -n "$TARGET" ] || die "give me the mod you downloaded: a .zip, a .rar, or a folder"
[ -e "$TARGET" ] || die "no such file or folder: $TARGET"

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

hdr "Reading the mod"

SRC=""
case "$TARGET" in
  *.zip|*.ZIP|*.rar|*.RAR|*.7z|*.7Z)
    WORK="$(mktemp -d)"
    if have unar; then
      unar -quiet -force-overwrite -output-directory "$WORK" "$TARGET" >/dev/null \
        || die "could not extract $TARGET"
    elif have 7z; then
      7z x -y -o"$WORK" "$TARGET" >/dev/null || die "could not extract $TARGET"
    elif have unzip && case "$TARGET" in *.zip|*.ZIP) true ;; *) false ;; esac; then
      unzip -q -o "$TARGET" -d "$WORK" || die "could not extract $TARGET"
    else
      die "no extractor available. Install one:  sudo apt install unar"
    fi
    ok "extracted the archive"
    SRC="$WORK"
    ;;
  *)
    [ -d "$TARGET" ] || die "$TARGET is neither a folder nor an archive I know"
    SRC="$TARGET"
    ;;
esac

# --- find the descriptor ----------------------------------------------------
UPLUGIN="$(find -L "$SRC" -name '*.uplugin' -type f 2>/dev/null | head -1)"
PAK="$(find -L "$SRC" -name '*.pak' -type f 2>/dev/null | head -1)"

if [ -n "$UPLUGIN" ]; then
  MOD_ROOT="$(dirname "$UPLUGIN")"
  MOD_NAME="$(basename "$UPLUGIN" .uplugin)"
  ok "descriptor: $(basename "$UPLUGIN")"
  ok "mod name:   $MOD_NAME"
  FOLDER_NAME="$(basename "$MOD_ROOT")"
  if [ "$FOLDER_NAME" != "$MOD_NAME" ]; then
    warn "the folder is called '$FOLDER_NAME' but the mod is '$MOD_NAME'"
    warn "that mismatch alone makes the game ignore it -- renaming on install"
  fi
elif [ -n "$PAK" ]; then
  # HelloRemastered and friends ship a bare .pak with no descriptor. Those go
  # straight into Mods/ as a single file.
  MOD_ROOT=""
  MOD_NAME="$(basename "$PAK" .pak)"
  ok "no .uplugin, but a packaged .pak: $(basename "$PAK")"
else
  err "this download has no .uplugin and no .pak in it"
  err "there is nothing here the retail game can load"
  exit 1
fi

# --- will the retail game run it? -------------------------------------------
if [ -z "$PAK" ]; then
  warn "no .pak anywhere in this mod -- only loose assets"
  warn "that makes it a MOD KIT mod: it runs inside the Hello Neighbor Mod"
  warn "Kit editor (free on the Epic launcher, about 25 GB), not in the game."
  warn "Nothing to install. Look for a version whose files include a .pak."
  exit 2
fi
ok "packed content found: $(basename "$PAK")  ($(du -shL "$PAK" 2>/dev/null | cut -f1))"

# Spaces in the folder name are a known cause of the mod never appearing.
SAFE_NAME="${MOD_NAME// /}"
if [ "$SAFE_NAME" != "$MOD_NAME" ]; then
  warn "removing spaces from the name: '$MOD_NAME' -> '$SAFE_NAME'"
fi

if [ "$ACTION" = "check" ]; then
  hdr "Verdict"
  ok "this mod should work -- install it with:"
  echo "      ./tools/install-mod.sh \"$TARGET\""
  exit 0
fi

# --- install ----------------------------------------------------------------
hdr "Installing into $MODS_DIR"
mkdir -p "$MODS_DIR"

DEST="$MODS_DIR/$SAFE_NAME"
if [ -e "$DEST" ]; then
  warn "replacing the existing $SAFE_NAME"
  rm -rf "$DEST"
fi

if [ -n "$MOD_ROOT" ]; then
  cp -rL "$MOD_ROOT" "$DEST"
  # the descriptor has to carry the folder's name, not the one it arrived with
  if [ ! -f "$DEST/$SAFE_NAME.uplugin" ]; then
    mv -f "$DEST/$(basename "$UPLUGIN")" "$DEST/$SAFE_NAME.uplugin"
  fi
  ok "installed: Mods/$SAFE_NAME/"
else
  cp -L "$PAK" "$MODS_DIR/$SAFE_NAME.pak"
  ok "installed: Mods/$SAFE_NAME.pak"
fi

cat <<EOF

  ${B}Done.${N} Now:

    1. Start Hello Neighbor from the shelf icon as usual.
    2. On the main menu choose ${B}MODDING${N}.
    3. Pick the mod, then ${B}Continue${N}.

  Not in the list? Run ${B}./tools/install-mod.sh --list${N} -- it flags the
  three things that hide a mod (missing .uplugin, missing .pak, name
  mismatch). Some older mods were built for game version 1.1.9 and will not
  load on the full release no matter where they are put.

EOF
