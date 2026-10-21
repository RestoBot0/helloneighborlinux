# Troubleshooting

**Always start here:** right-click the shelf icon → **Open the log folder**, and
read the newest `launch-*.log`. It records the backend chosen, the exe found, the
full argument list and Wine's output.

---

## Black screen, but I can hear the game

The most common Crostini failure, and the installer already guards against it.
If it still happens, exclusive fullscreen got re-enabled — usually by the in-game
options menu.

Fix: edit
`prefix/drive_c/users/<you>/AppData/Local/HelloNeighbor/Saved/Config/WindowsNoEditor/GameUserSettings.ini`

```ini
FullscreenMode=1
LastConfirmedFullscreenMode=1
PreferredFullscreenMode=1
```

(`0` = exclusive fullscreen — never use it here. `1` = borderless. `2` = windowed.)

Or just right-click the icon → **Play in a window**.

---

## "LowLevelFatalError ... can't be replaced with the new one of different type!"

```
LowLevelFatalError [File:Unknown] [Line: 1312]
Console object named 'r.RHIThread.Enable' can't be replaced with the
new one of different type!
```

**Cause:** a console variable was set in an `.ini` *before* the module that
owns it had registered it. UE4 creates an untyped placeholder from the ini
value; when the real variable registers later with a concrete type, the engine
refuses to reconcile them and hard-crashes.

It is always a config bug, never a Wine or GPU problem — the game got far
enough to parse your config, which means the wrapper is working.

**Known offenders — never put these in an ini:**

| Variable | Why |
|---|---|
| `r.RHIThread.Enable` | registered by the RHI module after config parse |
| `r.RHICmdBypass` | same |
| `rhi.SyncInterval` | same |
| `AllowConsoleInShipping` | **not a cvar at all** — a compile-time macro. Any name that doesn't exist becomes a placeholder landmine. |

**Fix** (removes them from the installed config, no reinstall):

```bash
find ~/.local/share/hello-neighbor/prefix -path '*HelloNeighbor*' -name 'Engine.ini' \
  -exec sed -i -E '/^(r\.RHIThread\.Enable|r\.RHICmdBypass|rhi\.SyncInterval|FX\.BatchAsync|FX\.EarlyScheduleAsync|AllowConsoleInShipping|con\.DebugEarlyDefault)=/d' {} +
```

**If it names a different variable,** delete that line from
`Engine.ini` the same way. The crash message always tells you exactly which
one, and nothing in `[SystemSettings]` is load-bearing — removing any single
line costs you a little performance at worst.

---

## It doesn't start at all

Work down this list:

1. Right-click → **Safe mode (OpenGL / DX10)**. If that works, Vulkan/DXVK is the
   problem — set `FORCE_BACKEND="wined3d"` in `launcher.conf`.
2. Run it from a terminal to see everything live:
   ```bash
   ~/.local/share/hello-neighbor/bin/hello-neighbor-launch --windowed --debug
   ```
3. Check Wine exists: `wine --version`
4. Check the exe was found: `grep exe: ~/.local/share/hello-neighbor/logs/*.log | tail -1`

---

## Poor frame rate

Open the console (`~` or `F1`) and run **`stat unit`**. Read which line is closest
to *Frame*:

- **GPU is the limit** → lower `r.ScreenPercentage` (try `70`), then shadows.
- **Draw is the limit** → this is Wine/translation overhead, *not* your settings.
  Lowering effects won't help much; lower the **resolution** instead, and make
  sure you're on DXVK rather than WineD3D (`grep backend ~/.local/share/hello-neighbor/logs/*.log | tail -1`).
- **Game is the limit** → CPU-side; close Chrome tabs. Crostini shares your RAM
  and cores with ChromeOS.

Quick wins, in order of impact:

```bash
# in launcher.conf
RES_W=1280
RES_H=720
```
```
# in the console, live
r.ScreenPercentage 70
r.ShadowQuality 0
sg.PostProcessQuality 0
```

---

## Stutter every few seconds (not low FPS — hitches)

Two likely causes:

1. **First-launch shader compilation.** Normal, happens once per area. The DXVK
   state cache in `~/.local/share/hello-neighbor/cache/dxvk/` persists it; the
   second playthrough of an area is smooth.
2. **Texture pool too large → swapping.** With 8 GB shared, `r.Streaming.PoolSize`
   above ~1500 starts swapping, which reads as random 1–2 second freezes. The
   default here is `1024`. Lower it to `700` if you're also running Chrome heavily.

---

## Crackly / stuttering audio

Already handled via `PULSE_LATENCY_MSEC=60`. If it persists, raise it:

```bash
# add to launcher.conf
export PULSE_LATENCY_MSEC=120
```

Also try `MaxChannels=16` under `[Audio]` in `Engine.ini` — the Crostini audio
bridge chokes above roughly 24 simultaneous voices, and that shows up as general
stutter, not just audio glitching.

---

## Mouse feels laggy / drifts / escapes the window

Mouse smoothing is already disabled in `Input.ini`. If the cursor escapes the
window on a scaled ChromeOS display, confirm:

```ini
DefaultViewportMouseCaptureMode=CapturePermanently_IncludingInitialMouseDown
DefaultViewportMouseLockMode=LockOnCapture
```

---

## The icon doesn't appear in the launcher

Crostini's `garcon` watches `~/.local/share/applications`. Nudge it:

```bash
update-desktop-database ~/.local/share/applications
# if still missing, restart the container from ChromeOS Settings > Developers
```

Confirm the file is valid:
```bash
desktop-file-validate ~/.local/share/applications/hello-neighbor.desktop
```

---

## "Unrecognised archive layout"

`install.sh` prints the top two levels of the archive when it can't find
`HelloNeighbor.exe`. Send me that output, or generate a full manifest:

```bash
./tools/make-manifest.sh ~/Downloads/HelloNeighbor.rar
```

---

## RAR won't extract

Debian's **`unrar-free` cannot read RAR5** and fails with a confusing error. The
installer deliberately prefers `unar` and `7zz`, both of which handle RAR5.

```bash
sudo apt install unar p7zip-full
```

**Multi-part archives** (`.part1.rar`, `.part2.rar`, … or `.rar`, `.r00`, `.r01`):
keep every part in the same folder and point `--rar` at the **first** one only.

---

## Starting completely over

```bash
./uninstall.sh --all        # removes game, prefix, icon, everything
./install.sh --rar ~/Downloads/HelloNeighbor.rar
```

Keeping the game but resetting only the config:

```bash
rm -rf ~/.local/share/hello-neighbor/prefix
./install.sh --game-dir ~/.local/share/hello-neighbor/game --no-deps
```

---

## Black screen / instant crash, log full of `GL_RGBA8_SNORM`

**Symptom.** The game reaches the loading screen, then dies. The Wine output
contains hundreds of:

```
err:d3d:wined3d_debug_callback: "GL_INVALID_ENUM in glTexBufferRange(internalFormat GL_RGBA8_SNORM)."
```

followed by a crash on the `wined3d_cs` thread:

```
page fault on write access to 0x0000000000000000
  memcpy
  <- wined3d_context_gl_unmap_bo_address   (context_gl.c:3125)
  <- wined3d_context_gl_copy_bo_address    (context_gl.c:3124)
  <- wined3d_buffer_load_location          (buffer.c:660)
  <- create_buffer_texture                 (view.c:258)
  <- create_buffer_view                    (view.c:296)
  <- wined3d_shader_resource_view_gl_cs_init (view.c:1024)
```

**Cause.** This is the WineD3D (OpenGL) path, not DXVK. Unreal creates a
Direct3D 11 *buffer* shader-resource-view in `R8G8B8A8_SNORM`. WineD3D maps
that to a GL texture buffer with internal format `GL_RGBA8_SNORM` — but
`GL_RGBA8_SNORM` is **not** in OpenGL's list of legal texture-buffer internal
formats. The driver rejects the call, WineD3D does not check the error, the
buffer object is left with a null mapped address, and the next upload
`memcpy`s into it.

**This cannot be fixed with any `.ini` setting.** UE4 uses that format
unconditionally. The only real fix is to stop using WineD3D — i.e. get DXVK
running on Vulkan, which has a native `R8G8B8A8_SNORM` and no such limitation.

Run `./tools/enable-vulkan.sh`, then re-run `./install.sh`.

---

## `vkCreateInstance: Found no drivers!` inside Crostini

Two separate problems hide behind this one message. Check them in order.

### 1. Debian 12's Mesa has no Venus driver

Bookworm ships Mesa 22.3.6, which predates the Venus virtio-gpu Vulkan
driver entirely. Confirm with:

```bash
ls /usr/share/vulkan/icd.d/
```

If there is no `virtio_icd*.json`, the driver is simply not installed. The
`intel_icd`, `intel_hasvk_icd` and `radeon_icd` files present by default are
useless here — inside Crostini the DRM device is virtio-gpu, not a real Intel
or AMD card. `lvp_icd` is CPU-only and far too slow to play on.

Fix: `./tools/enable-vulkan.sh`, which pulls Mesa 25.x from
`bookworm-backports`.

> Install the whole Mesa set in a *single* `apt install -t bookworm-backports`
> command. Upgrading packages one at a time fails with
> `mesa-libgallium : Depends: libllvm15 but it is not installable`.

### 2. The driver is installed but the filename is wrong

This is the confusing one. After installing, the loader *still* says it found
no drivers, and complains about files that look almost right:

```
loader_get_json: Failed to open JSON file /usr/share/vulkan/icd.d/virtio_icd.i686.json
loader_get_json: Failed to open JSON file /usr/share/vulkan/icd.d/virtio_icd.x86_64.json
vkCreateInstance: Found no drivers!
```

ChromeOS presets `VK_ICD_FILENAMES` in every Crostini shell to those two
architecture-suffixed paths. Debian's Mesa package installs the file as plain
`virtio_icd.json`, with no suffix. A *set-but-dangling* `VK_ICD_FILENAMES` is
worse than an unset one: the Vulkan loader treats the list as authoritative
and skips its own scan of `/usr/share/vulkan/icd.d`, so a perfectly good
driver sitting right there is never seen.

Fix — give the file the names ChromeOS is asking for:

```bash
sudo ln -sfn virtio_icd.json /usr/share/vulkan/icd.d/virtio_icd.x86_64.json
sudo ln -sfn virtio_icd.json /usr/share/vulkan/icd.d/virtio_icd.i686.json
```

`tools/enable-vulkan.sh` now does this automatically, and the launcher
independently prunes dangling `VK_ICD_FILENAMES` entries at startup.

**Success looks like:**

```
GPU0:
    apiVersion   = 1.3.269
    driverName   = venus
    deviceName   = Virtio-GPU Venus (Intel(R) Xe Graphics (TGL GT2))
    deviceType   = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
```

`INTEGRATED_GPU` is the important word. If it says `CPU` / `llvmpipe`, you are
on software rendering and the game will be unplayable.

---

## `MESA: error: Use of VkSurfacePresentModeCompatibilityEXT ...`

Harmless when it comes from `vulkaninfo` itself. If the *game* tears badly or
hangs on the first frame, it is the known Venus X11/XWayland presentation bug.
The launcher applies the standard workaround automatically on Crostini:

```
MESA_VK_WSI_DEBUG=sw
```

This moves only the final "copy the finished frame into the window" step to
the CPU. All actual rendering stays on the GPU, so the cost is a few percent —
it is *not* a fall back to software rendering. Set `HN_VK_WSI_SW=0` in
`~/.local/share/hello-neighbor/launcher.conf` to try the native path.

---

## DXVK says `No adapters found` after Vulkan is working

DXVK 2.4 and newer require 256 bytes of push-constant data, which Venus
(passing through Intel's limit of 128) does not advertise. The log looks like:

```
Found device: Virtio-GPU Venus (Intel(R) Graphics)
Skipping: Device does not support 256 of push data
No adapters found. A Vulkan 1.3 capable setup is required.
```

The installer pins DXVK 2.3.1, which predates that requirement. If you still
hit it, drop to the 1.x series:

```bash
./install.sh --game-dir ~/'Hello Neighbor FILE FOR ARENA' --no-deps --dxvk-ver 1.10.3
```

To go back to OpenGL entirely, re-run with `--no-dxvk` — the installer will
properly uninstall the DXVK DLLs and restore Wine's builtins.

---

## `Assertion failed! dlls/winevulkan/loader_thunks.c ... Expression: !status`

**Symptom.** A Wine dialog appears before the game draws anything:

```
Assertion failed!
File: dlls/winevulkan/loader_thunks.c
Line: 4850
Expression: "!status"
```

**Cause.** Nothing is wrong with your GPU, driver or the game. `winevulkan`
is Wine's bridge between the Windows-side Vulkan API and the real Linux
driver, and it is built from generated *thunks* — one small forwarding
function per Vulkan entry point, fixed at the time that Wine was compiled.

When something asks for an entry point the installed Wine was never built to
forward, the call into the Unix side fails, `status` is non-zero, and the
assertion kills the process.

Debian 12 ships **Wine 8.0 (January 2023)**. Our `enable-vulkan.sh` installs
**Mesa 25.0.7 (2025)**, which advertises much newer extensions — including
the surface/swapchain maintenance ones. DXVK 2.x sees them advertised and
uses them. Wine 8.0 has never heard of them. That version gap is the whole
bug.

> This is also why `vulkaninfo` printed
> `MESA: error: Use of VkSurfacePresentModeCompatibilityEXT ...` earlier —
> the same new extension family.

**Two fixes, either works.**

*Keep Wine 8, use an older DXVK.* DXVK 1.10.x targets Vulkan 1.1 and stays
inside what Wine 8 knows how to forward:

```bash
./install.sh --game-dir ~/'Hello Neighbor FILE FOR ARENA' --no-deps --dxvk-ver 1.10.3
```

*Or upgrade Wine* to 9/10, which implements the modern entry points:

```bash
./install.sh --game-dir ~/'Hello Neighbor FILE FOR ARENA' --winehq
```

The installer now checks `wine --version` and automatically drops to DXVK
1.10.3 when Wine is older than 9.0, so a plain re-run picks the working
combination on its own. Pass `--dxvk-ver` to override that choice.

**Why not just stay on the old Mesa?** Because without Mesa 25 there is no
Vulkan at all in Crostini, and without Vulkan the only path is WineD3D,
which cannot render this game (see the `GL_RGBA8_SNORM` section above).
Old Mesa and new DXVK are both dead ends; new Mesa with a matched
DXVK/Wine pair is the one combination that works.

---

## Crash after a few seconds: `D3D11Viewport.cpp:304 ... error 887A0020`

**Symptom.** The game starts, the rendering thread runs for a while, then:

```
LowLevelFatalError [Line: 826]
Rendering thread exception:
LowLevelFatalError [Line: 251]
Result failed
 at ...\D3D11RHI\Private\D3D11Viewport.cpp:304
 with error 887A0020
```

**This is good news in disguise.** Everything up to and including rendering
worked. `887A0020` is `DXGI_ERROR_DRIVER_INTERNAL_ERROR`, and
`D3D11Viewport.cpp:304` is UE4 checking the result of **`Present()`** — the
call that hands a finished frame to the screen. The game drew the frame and
then failed to display it.

**Cause.** Venus's presentation path through ChromeOS's X server
(`sommelier`, an XWayland) is buggy. The GPU work completes; the handoff to
the window system fails and DXVK reports a driver-internal error upward.

**Fix.** Edit `~/.local/share/hello-neighbor/launcher.conf` and set:

```ini
HN_VK_WSI_SW=1
```

Or test it without editing anything:

```bash
HN_VK_WSI_SW=1 ~/.local/share/hello-neighbor/bin/hello-neighbor-launch
```

That sets `MESA_VK_WSI_DEBUG=sw`, which moves **only** the final
frame-to-window copy onto the CPU. All actual rendering stays on the GPU, so
the cost is a few percent — it is not a fall back to software rendering.

If that is not enough, also try a Wine virtual desktop, which gives Wine a
single top-level X window it owns outright:

```ini
VDESK=1
```

> Settings precedence is **environment variable > launcher.conf > built-in
> default**, so a one-off `HN_VK_WSI_SW=1 ...` on the command line always
> wins over the config file.

The installer also now writes `dxgi.syncInterval = 0` into `dxvk.conf`.
Venus's queued (vsync/FIFO) present path is the one that misbehaves, and
ChromeOS composites and paces frames itself, so there is nothing to gain by
waiting on it inside the game.
