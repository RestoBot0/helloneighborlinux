#!/usr/bin/env bash
#
# Puts FoxyReignited back exactly as it was downloaded from ModDB.
#
# Use this if the mod is damaged and the .bak is gone. It does NOT apply the
# Cat patch - it restores the untouched mod, so the game opens again and you
# get plain Foxy. Run APPLY.sh afterwards if you want the Cat back.
#
#   ./RESTORE.sh                 find the Mods folder automatically
#   ./RESTORE.sh /path/to/Mods   tell it where the Mods folder is
#
set -Eeuo pipefail

BRANCH=arena/50710a4d-helloneighborlinux
BASE="https://raw.githubusercontent.com/RestoBot0/helloneighborlinux/refs/heads/$BRANCH/incoming"
ZIP_MD5=37da2176c1c20ecf761fdbdbca63cf55
PAK_MD5=4dbe8bfc2040e3624657e983e706ab13
PAK_SIZE=169167798

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v curl  >/dev/null || die "curl is not installed"
command -v unzip >/dev/null || die "unzip is not installed"

# ---------------------------------------------------------------- find Mods
MODS="${1:-}"
if [ -z "$MODS" ]; then
    # -L is needed because the install's game/ directory is normally a symlink.
    # dosdevices/prefix MUST be pruned: a Wine prefix contains z: -> / and
    # find would walk the whole root filesystem and then spin on symlink loops.
    for root in \
        "$HOME/.local/share/hello-neighbor/game" \
        "$HOME/Hello Neighbor FILE FOR ARENA" \
        "$HOME"
    do
        [ -e "$root" ] || continue
        MODS="$(find -L "$root" \
                  \( -name dosdevices -o -name prefix -o -name '.wine*' \) -prune -o \
                  -type d -path '*/HelloNeighbor/Mods' -print 2>/dev/null | head -1)"
        [ -n "$MODS" ] && break
    done
fi
[ -n "$MODS" ] && [ -d "$MODS" ] || die "could not find the HelloNeighbor/Mods folder.
Pass it yourself:  ./RESTORE.sh \"/path/to/HelloNeighbor/Mods\""
say "mods folder : $MODS"

# ------------------------------------------------------------ fetch the mod
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say "downloading : the original mod, in two pieces (28 MB)"
for part in part-aa part-ab; do
    curl -fsSL --retry 3 -o "$WORK/$part" "$BASE/FoxyReignited.zip.$part" \
        || die "download failed for $part - check the network and try again"
done
cat "$WORK/part-aa" "$WORK/part-ab" > "$WORK/FoxyReignited.zip"

GOT="$(md5sum "$WORK/FoxyReignited.zip" | cut -d' ' -f1)"
[ "$GOT" = "$ZIP_MD5" ] || die "download is damaged (md5 $GOT, expected $ZIP_MD5). Nothing was changed."
say "checksum    : OK, matches the ModDB original"

unzip -q "$WORK/FoxyReignited.zip" -d "$WORK/x"
NEWPAK="$WORK/x/FoxyReignited/Content/Paks/WindowsNoEditor/FoxyReignited.pak"
[ -f "$NEWPAK" ] || die "the zip did not contain the pak. Nothing was changed."

GOT="$(stat -c %s "$NEWPAK")"
[ "$GOT" = "$PAK_SIZE" ] || die "unpacked pak is $GOT bytes, expected $PAK_SIZE. Nothing was changed."
GOT="$(md5sum "$NEWPAK" | cut -d' ' -f1)"
[ "$GOT" = "$PAK_MD5" ] || die "unpacked pak md5 is $GOT, expected $PAK_MD5. Nothing was changed."
say "unpacked    : pak verified, $PAK_SIZE bytes"

# ------------------------------------------------- swap it in, keeping a copy
# Everything above this line is read-only. The install is only touched now
# that the replacement has been fully verified.
if [ -e "$MODS/FoxyReignited" ]; then
    # Out of the game tree, not just renamed inside it: the game scans Mods/
    # for paks, and a damaged one sitting next to the good one could still be
    # mounted. Kept rather than deleted, in case it is worth looking at.
    OLD="$HOME/FoxyReignited.damaged-$(date +%Y%m%d-%H%M%S)"
    mv "$MODS/FoxyReignited" "$OLD"
    say "moved aside : $OLD  (out of the game folder)"
fi
cp -r "$WORK/x/FoxyReignited" "$MODS/FoxyReignited"
say "restored    : $MODS/FoxyReignited"

cat <<'MSG'

Done. FoxyReignited is byte-for-byte the mod as downloaded.

Start the game now and check it opens. In the Modding menu you will get plain
Foxy, not the Cat - that is expected, this only repairs the damage.

If it opens, run APPLY.sh to put the Cat back. A fresh .bak will be made from
this clean pak, so the undo path exists again.

If it still does not open, the mod was not the problem. Say so and do not run
anything else.
MSG
