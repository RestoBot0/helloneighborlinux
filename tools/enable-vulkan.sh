#!/usr/bin/env bash
# ===========================================================================
#  enable-vulkan.sh -- get hardware Vulkan (Venus) working in ChromeOS Crostini
#
#  WHY THIS EXISTS
#  ---------------
#  Crostini gives the container a virtio-gpu. Two Mesa drivers talk to it:
#     virgl  -> OpenGL   (shipped in Debian 12, works out of the box)
#     venus  -> Vulkan   (NOT in Debian 12 -- Mesa 22.3.6 predates it)
#
#  ChromeOS already sets VK_ICD_FILENAMES to virtio_icd.*.json, so the loader
#  looks for Venus and fails with:
#     "Failed to open JSON file /usr/share/vulkan/icd.d/virtio_icd.x86_64.json"
#     "vkCreateInstance: Found no drivers!"
#
#  bookworm-backports carries Mesa 25.x, which does ship Venus. This script
#  pulls Mesa from backports and verifies the result.
#
#  WHY YOU WANT IT
#  ---------------
#  Without Vulkan, Wine must use WineD3D (D3D11 -> OpenGL). WineD3D cannot
#  express some D3D11 buffer formats in GL -- notably R8G8B8A8_SNORM, which
#  makes it emit glTexBufferRange(GL_RGBA8_SNORM), an illegal enum. Unreal
#  Engine 4 uses that format, so the game dies with a null-pointer crash
#  inside wined3d. DXVK (D3D11 -> Vulkan) has no such limitation.
# ===========================================================================
set -Eeuo pipefail

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
ok()   { printf '  %s*%s %s\n' "$G" "$N" "$1"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$1"; }
err()  { printf '  %sx%s %s\n' "$R" "$N" "$1" >&2; }
hdr()  { printf '\n%s==> %s%s\n' "$B" "$1" "$N"; }

hdr "Where we're starting from"
echo "  Mesa (GL):  $(glxinfo -B 2>/dev/null | awk -F': ' '/OpenGL version/{print $2}' || echo '?')"
echo "  Renderer:   $(glxinfo -B 2>/dev/null | awk -F': ' '/OpenGL renderer/{print $2}' || echo '?')"
echo "  ICDs:       $(ls /usr/share/vulkan/icd.d/ 2>/dev/null | tr '\n' ' ')"

if ls /usr/share/vulkan/icd.d/virtio_icd*.json >/dev/null 2>&1; then
  ok "virtio_icd (Venus) is already installed"
  ALREADY=1
else
  warn "virtio_icd (Venus) is MISSING -- this is what we're fixing"
  ALREADY=0
fi

# ---------------------------------------------------------------------------
if [ "$ALREADY" = "0" ]; then
hdr "Adding bookworm-backports"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")"
if [ "$CODENAME" != "bookworm" ]; then
  warn "You're on '$CODENAME', not bookworm. Using ${CODENAME}-backports instead."
fi
if [ ! -f /etc/apt/sources.list.d/backports.list ]; then
  echo "deb http://deb.debian.org/debian ${CODENAME}-backports main contrib non-free non-free-firmware" \
    | sudo tee /etc/apt/sources.list.d/backports.list >/dev/null
  ok "added ${CODENAME}-backports"
else
  ok "backports already configured"
fi
sudo apt-get update -qq || warn "apt update reported warnings"

hdr "Installing Mesa 25.x from backports"
# These must go in together. Installing mesa-vulkan-drivers alone hits
# "mesa-libgallium depends libllvm15 but it is not installable", because the
# backported Mesa needs the backported LLVM runtime too.
set +e
sudo apt-get install -y -t "${CODENAME}-backports" \
  mesa-vulkan-drivers \
  mesa-libgallium \
  libgl1-mesa-dri \
  libegl-mesa0 \
  libglx-mesa0 \
  mesa-utils \
  libvulkan1
RC=$?
set -e
if [ $RC -ne 0 ]; then
  err "backports install failed"
  echo "  Try it by hand so you can read the dependency error:"
  echo "    sudo apt install -t ${CODENAME}-backports mesa-vulkan-drivers mesa-libgallium libgl1-mesa-dri libegl-mesa0 libglx-mesa0"
  exit 1
fi
ok "Mesa installed: $(dpkg -l mesa-vulkan-drivers 2>/dev/null | awk '/^ii/{print $3}')"
fi

# ---------------------------------------------------------------------------
hdr "GPU device permissions"
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx render; then
  sudo usermod -aG render "$USER" && ok "added $USER to the 'render' group"
  NEED_RESTART=1
else
  ok "already in the 'render' group"
  NEED_RESTART=0
fi
ls -l /dev/dri/ 2>/dev/null | sed 's/^/    /'

# ---------------------------------------------------------------------------
hdr "Verifying Vulkan"
if ls /usr/share/vulkan/icd.d/virtio_icd*.json >/dev/null 2>&1; then
  ok "virtio_icd present: $(ls /usr/share/vulkan/icd.d/virtio_icd*.json | tr '\n' ' ')"
else
  err "virtio_icd still missing after install -- backports Mesa may not have applied"
  echo "    check with: dpkg -L mesa-vulkan-drivers | grep -i virtio"
  exit 1
fi

echo
if timeout 30 vulkaninfo --summary 2>&1 | grep -qiE 'driverName\s*=\s*venus|Venus'; then
  ok "${B}Venus is working -- hardware Vulkan is live${N}"
  timeout 30 vulkaninfo --summary 2>&1 | grep -iE 'deviceName|driverName|apiVersion|deviceType' | head -8 | sed 's/^/    /'
  echo
  ok "Next: re-run the installer so it picks DXVK instead of WineD3D:"
  echo "       cd ~/helloneighborlinux && ./install.sh --game-dir ~/'Hello Neighbor FILE FOR ARENA' --no-deps"
else
  warn "Venus did not come up cleanly. Diagnostics:"
  timeout 30 vulkaninfo --summary 2>&1 | head -20 | sed 's/^/    /'
  echo
  if [ "${NEED_RESTART:-0}" = "1" ]; then
    warn "You were just added to the 'render' group -- that needs a container restart."
  fi
  echo "  Try, in order:"
  echo "    1. Shut down Linux from ChromeOS Settings > Developers, then reopen Terminal"
  echo "    2. Check chrome://flags/#crostini-gpu-support is Enabled"
  echo "    3. Force the ICD explicitly:"
  echo "         VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/virtio_icd.x86_64.json vulkaninfo --summary"
  echo "    4. If presentation hangs rather than fails, Venus's X11 WSI is known"
  echo "       to misbehave in Crostini. Work around it with:"
  echo "         export MESA_VK_WSI_DEBUG=sw"
fi
