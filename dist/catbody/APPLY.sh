#!/usr/bin/env bash
# Puts the Cat's body onto Foxy's working brain.
# Rebuilds FoxyReignited.pak with one asset replaced. Keeps a .bak.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$(cd "$HERE/../../tools" && pwd)"
PAK="${1:-}"
if [ -z "$PAK" ]; then
  PAK="$(find "$HOME/.local/share/hello-neighbor/game" -name FoxyReignited.pak 2>/dev/null | head -1)"
fi
[ -n "$PAK" ] && [ -f "$PAK" ] || { echo "Could not find FoxyReignited.pak. Pass its path as an argument."; exit 1; }
echo "patching: $PAK"
[ -f "$PAK.bak" ] || cp "$PAK" "$PAK.bak"
python3 "$TOOLS/rebuild-pak.py" "$PAK.bak" "$PAK.new" \
    --replace "AI_Foxy_Original.uasset=$HERE/AI_Foxy_Original.uasset"
mv "$PAK.new" "$PAK"
echo
echo "Done. In the Modding menu pick FoxyReignited (not Cat_In_The_Hat)."
echo "Keep the stock Cat_In_The_Hat mod installed - its files supply the body."
