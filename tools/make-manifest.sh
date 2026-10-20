#!/usr/bin/env bash
# ===========================================================================
#  make-manifest.sh -- describe a Hello Neighbor archive WITHOUT extracting it
#
#  Produces a small text file (tens of KB) listing what is inside the .rar,
#  which is all that's needed to confirm the build and tailor the configs.
#  No game data leaves your machine -- it is just a list of names and sizes.
#
#  Usage:
#      ./tools/make-manifest.sh ~/Downloads/HelloNeighbor.rar
#      ./tools/make-manifest.sh ~/Downloads/HelloNeighbor/      (a folder works too)
#
#  Output:  ./manifest.txt
# ===========================================================================
set -Eeuo pipefail

TARGET="${1:-}"
OUT="${2:-$(pwd)/manifest.txt}"

if [ -z "$TARGET" ]; then
  echo "usage: $0 <archive.rar | extracted-folder> [output.txt]" >&2
  exit 1
fi
[ -e "$TARGET" ] || { echo "No such file or folder: $TARGET" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

{
  echo "=============================================================="
  echo " Hello Neighbor archive manifest"
  echo " generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo " target   : $TARGET"
  echo "=============================================================="
  echo
  echo "--- host ---"
  echo "kernel : $(uname -srm)"
  [ -f /etc/os-release ] && echo "distro : $(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "cpu    : $(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ //')"
  echo "cores  : $(nproc)"
  echo "ram    : $(awk '/MemTotal/{printf "%.1f GB", $2/1048576}' /proc/meminfo)"
  echo "wine   : $(wine --version 2>/dev/null || echo 'not installed')"
  echo "vulkan : $(ls /usr/share/vulkan/icd.d/*.json 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ' || echo none)"
  if have vulkaninfo; then
    echo "gpu    : $(timeout 20 vulkaninfo --summary 2>/dev/null | awk -F= '/deviceName/{print $2; exit}' | sed 's/^ //')"
  elif have glxinfo; then
    echo "gpu    : $(timeout 20 glxinfo -B 2>/dev/null | awk -F: '/Device:/{print $2; exit}')"
  fi
  echo

  if [ -d "$TARGET" ]; then
    echo "--- type: EXTRACTED FOLDER ---"
    echo "total size: $(du -sh "$TARGET" 2>/dev/null | cut -f1)"
    echo
    echo "--- directory tree (3 levels) ---"
    find "$TARGET" -maxdepth 3 -type d 2>/dev/null | sed "s|^$TARGET|.|" | sort | head -200
    echo
    echo "--- executables ---"
    find "$TARGET" -maxdepth 7 -type f -iname '*.exe' 2>/dev/null \
      | sed "s|^$TARGET|.|" | sort | head -60
    echo
    echo "--- .pak files ---"
    find "$TARGET" -maxdepth 7 -type f -iname '*.pak' -printf '%10s  %p\n' 2>/dev/null \
      | sed "s|$TARGET|.|" | sort -k2 | head -60
    echo
    echo "--- version / build files ---"
    find "$TARGET" -maxdepth 5 -type f \
      \( -iname '*.version' -o -iname 'build*.txt' -o -iname 'manifest*' -o -iname 'version*' \) \
      2>/dev/null | sed "s|^$TARGET|.|" | head -30
    echo
    for vf in $(find "$TARGET" -maxdepth 5 -type f -iname '*.version' 2>/dev/null | head -3); do
      echo "--- contents of $(basename "$vf") ---"; head -40 "$vf"; echo
    done
    echo "--- bundled .ini files ---"
    find "$TARGET" -maxdepth 6 -type f -iname '*.ini' 2>/dev/null | sed "s|^$TARGET|.|" | head -40
    echo
    echo "--- plugins / mods folders ---"
    find "$TARGET" -maxdepth 6 -type d \( -iname 'Plugins' -o -iname 'Mods' \) 2>/dev/null \
      | sed "s|^$TARGET|.|" | head -20

  else
    echo "--- type: ARCHIVE ---"
    echo "file : $(basename "$TARGET")"
    echo "size : $(du -h "$TARGET" | cut -f1)  ($(stat -c%s "$TARGET") bytes)"
    echo "sha256 (first 64 MB, for identification):"
    head -c 67108864 "$TARGET" | sha256sum | awk '{print "       "$1}'
    echo
    echo "--- sibling parts (multi-part archives) ---"
    ls -la "$(dirname "$TARGET")" 2>/dev/null \
      | grep -iE '\.(rar|r[0-9]{2}|part[0-9]+\.rar|zip|z[0-9]{2}|00[0-9])$' | head -40
    echo
    echo "--- full file listing ---"
    if have unar && have lsar; then
      lsar -l "$TARGET" 2>&1 | head -4000
    elif have 7zz; then
      7zz l "$TARGET" 2>&1 | head -4000
    elif have 7z; then
      7z l "$TARGET" 2>&1 | head -4000
    elif have unrar; then
      unrar l "$TARGET" 2>&1 | head -4000
    elif have bsdtar; then
      bsdtar -tvf "$TARGET" 2>&1 | head -4000
    else
      echo "!! No archive lister installed."
      echo "!! Run:  sudo apt install unar p7zip-full"
      echo "!! Then re-run this script."
    fi
  fi

  echo
  echo "=============================================================="
  echo " end of manifest"
  echo "=============================================================="
} > "$OUT" 2>&1

LINES=$(wc -l < "$OUT")
SIZE=$(du -h "$OUT" | cut -f1)
echo "Manifest written: $OUT"
echo "  $LINES lines, $SIZE"
echo
echo "Next: commit and push it, e.g."
echo "    git add manifest.txt && git commit -m 'archive manifest' && git push"
