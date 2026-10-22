#!/usr/bin/env bash
#
# Puts the Cat's body onto Foxy's working brain.
#
# Rebuilds FoxyReignited.pak with AI_Foxy_Original.uasset replaced. The
# original is kept as <pak>.bak and every run rebuilds from that backup, so
# running this twice is safe.
#
#   ./APPLY.sh                 find the pak automatically
#   ./APPLY.sh /path/to.pak    tell it where the pak is
#
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# rebuild-pak.py expects patch-pak.py beside it. Accept either layout:
# downloaded flat next to this script, or sitting in the repo's tools/.
if [ -f "$HERE/rebuild-pak.py" ]; then
    TOOLS="$HERE"
elif [ -f "$HERE/../../tools/rebuild-pak.py" ]; then
    TOOLS="$(cd "$HERE/../../tools" && pwd)"
else
    echo "error: rebuild-pak.py not found next to this script or in ../../tools" >&2
    exit 1
fi
[ -f "$TOOLS/patch-pak.py" ] || { echo "error: patch-pak.py must sit beside rebuild-pak.py in $TOOLS" >&2; exit 1; }

ASSET="$HERE/AI_Foxy_Original.uasset"
[ -f "$ASSET" ] || { echo "error: AI_Foxy_Original.uasset not found in $HERE" >&2; exit 1; }

PAK="${1:-}"
if [ -z "$PAK" ]; then
    # -L is essential: the install's game/ directory is usually a symlink to
    # wherever the game really lives, and plain find will not descend into it.
    #
    # But -L makes a Wine prefix lethal: prefix/dosdevices/z: points at /, so
    # find walks the whole root filesystem and then spins forever inside
    # /dev/.lxc/sys/... emitting "File system loop detected". Prune the Wine
    # directories before descending.
    for root in \
        "$HOME/.local/share/hello-neighbor/game" \
        "$HOME/Hello Neighbor FILE FOR ARENA" \
        "$HOME"
    do
        [ -e "$root" ] || continue
        PAK="$(find -L "$root" \
                 \( -name dosdevices -o -name prefix -o -name '.wine*' \) -prune -o \
                 -name 'FoxyReignited.pak' -print 2>/dev/null | head -1)"
        [ -n "$PAK" ] && break
    done
fi

if [ -z "$PAK" ] || [ ! -f "$PAK" ]; then
    cat >&2 <<'MSG'
error: could not find FoxyReignited.pak.

Locate it yourself with:

    find -L ~ \( -name dosdevices -o -name prefix \) -prune -o \
         -name 'FoxyReignited.pak' -print

then re-run this script with the path:

    ./APPLY.sh "/the/path/FoxyReignited.pak"
MSG
    exit 1
fi

echo "pak   : $PAK"
echo "asset : $ASSET"

# Always rebuild from a pristine backup so repeat runs cannot stack up.
if [ ! -f "$PAK.bak" ]; then
    cp "$PAK" "$PAK.bak"
    echo "backup: $PAK.bak"
else
    echo "backup: $PAK.bak (already existed, rebuilding from it)"
fi

python3 "$TOOLS/rebuild-pak.py" "$PAK.bak" "$PAK.new" \
    --replace "AI_Foxy_Original.uasset=$ASSET"

mv "$PAK.new" "$PAK"

cat <<'MSG'

Done.

In the Modding menu pick FoxyReignited - NOT Cat_In_The_Hat. The Cat you see
is Foxy's class wearing the Cat's body.

Keep the Cat_In_The_Hat mod installed. Its pak supplies the Cat mesh and the
Cat sounds; this build points at them by name. It does NOT use the Cat's own
animation blueprint - that one has no montage slot, so door opening and most
other actions silently did nothing. It uses the stock Neighbour one instead,
which drives the Cat mesh fine because the Cat is rigged to the Neighbour's
skeleton.

To undo:  cp "<pak>.bak" "<pak>"   (the .bak is never overwritten)
MSG
