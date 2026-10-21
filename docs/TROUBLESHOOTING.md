# Troubleshooting

## SOLVED: "it launches, shows the tinyBuild logo, then vanishes after ~15 seconds"

This was the big one. It took about fifty debugging steps and it was never a
Linux, Wine, Vulkan or graphics problem at all.

**Cause.** *Hello Neighbor* bundles an old build of OpenSSL (used by its
online/analytics code). That OpenSSL predates **SHA-NI**, a set of CPU
instructions Intel first shipped on **10th-generation Core** chips. On a 10th
gen or newer CPU it detects SHA-NI, takes a code path it was never built to
run, corrupts memory, and the process dies with `0xC0000005` *before* Unreal's
crash handler is installed. That explains every symptom we saw:

* no Unreal crash report (`rc=5`, handler never ran)
* identical failure on **every** graphics configuration, including `lvp`
  (lavapipe) with no GPU in the loop at all
* `err:seh:call_seh_handlers invalid frame` — generic "this stack was
  scribbled on", not a graphics fault
* the widely-reported community workaround *"turn your WiFi off and it
  launches"* — same bug, approached from the other end

**Fix.** Set the environment variable `OPENSSL_ia32cap` to `:~0x20000000`.
The leading colon selects OpenSSL's *second* capability word; `~0x20000000`
clears bit 29 of it, the SHA-NI bit. OpenSSL then behaves as it would on a
9th-gen chip. Nothing else changes.

This is **tinyBuild's own documented fix**, from their support article
*"[PC] The game crashes at start"*, which says it applies to *"players with
10th Gen Intel CPUs or newer (11th, 12th, 13th, etc.)"* and warns: *"Make sure
to include the ':' on Value and leave no gaps — formatting matters!"*

**You do not have to do anything.** The launcher exports it on every run
(Wine makes the Unix shell environment visible to the Windows process it
starts — see `wine(1)`, ENVIRONMENT). Confirm it in the log:

```
OpenSSL CPU workaround on (OPENSSL_ia32cap=:~0x20000000)
```

To test without it: `HN_OPENSSL_FIX=0 ~/.local/share/hello-neighbor/bin/hello-neighbor-launch`
(or `OPENSSL_FIX=0` in `launcher.conf`). The only reason to do that is to
confirm the crash comes back.

tinyBuild list two other fixes for the same crash, worth knowing if it ever
returns: **remove all mods**, and **block the game in the firewall / go
offline**.

### Verified on the target machine

| Thing we changed | Variants tried | Result |
|---|---|---|
| DXVK version | 2.3.1, 1.10.3 | crashed both |
| Vulkan driver | Venus (GPU), lavapipe (CPU only) | crashed both |
| Window system | winex11.drv, winewayland.drv | crashed both |
| `MESA_VK_WSI_DEBUG=sw` | on, off | crashed both |
| Wine sync | esync/fsync on, off | crashed both |
| Audio | on, `HN_NOSOUND=1` | crashed both |
| Window mode | windowed, virtual desktop, several resolutions | crashed all |
| CPU topology | `WINE_CPU_TOPOLOGY=4:0,2,4,6` | crashed |
| **`OPENSSL_ia32cap=:~0x20000000`** | — | **game runs** |

Lesson for next time: search the **game's name plus the symptom** before
spending days on the platform underneath it.

---

## The shelf/launcher still shows the old icon

Two separate causes, both now handled by `./install.sh`.

**1. The installer was overwriting it.** `install.sh` used to call
`tools/extract-icon.sh` unconditionally, which pulls the artwork out of
`HelloNeighbor.exe` and reinstalls it at every size — wiping the icon that had
been installed moments earlier. Extraction is now opt-in (`--extract-icon`).

**2. ChromeOS caches app icons outside the container.** A daemon called
`garcon` watches the applications directories and reports the app list to
ChromeOS, which then asks garcon for each icon — **but only when an app
appears or disappears**. Editing the `.desktop` file, replacing the PNG, and
`gtk-update-icon-cache` all change nothing, because the stale copy lives on
the ChromeOS side where the container cannot reach it.

The only reliable fix is to make the app *disappear and come back*:

```bash
./tools/refresh-icon.sh          # removes the entry, waits 25s, puts it back
./tools/refresh-icon.sh --wait 90        # if 25s was not long enough
./tools/refresh-icon.sh --image ~/my.png # set a new icon and refresh
```

A reinstall now does this automatically whenever a launcher entry already
exists. The icon is also installed under a name derived from a hash of its own
bytes (`hello-neighbor-bc1860e1`), so a changed image always arrives under a
name ChromeOS has never cached.

If the icon is **pinned to the shelf**, the pin holds its own copy: unpin it,
then re-pin from the launcher. Worst case ChromeOS only releases it after a
device restart — nothing inside Crostini can force that.

Notes: ChromeOS accepts **PNG only** (SVG is ignored), and `.desktop` entries
with `Terminal=true` are not shown at all.

---

## Installing mods

Use `./tools/install-mod.sh <the thing you downloaded>` — zip, rar or folder.

Hello Neighbor loads mods the way UE4 loads plugins. The game scans
`HelloNeighbor/Mods/`, finds a `.uplugin` descriptor in each sub-folder, and
mounts the `.pak` packed inside it:

```
HelloNeighbor/Mods/
  MyMod/
    MyMod.uplugin
    Content/Paks/.../MyMod.pak
```

**Which mods work in the game?** Only ones containing a `.pak`. If a download
has a `.uplugin` and loose `.uasset` files but no `.pak`, it is a **Mod Kit**
mod: it runs inside the Hello Neighbor Mod Kit editor (free on the Epic
launcher, ~25 GB), never in the retail game.

**The three reasons a good mod never appears in the MODDING menu**, all of
which `install-mod.sh` fixes automatically:

1. The folder name does not match the `.uplugin` name. Downloads arrive as
   `TheNeighborsComeback2/` holding `TheNeighborsComeback.uplugin` all the
   time, and the game then shows nothing.
2. Spaces in the folder name.
3. It is still a `.zip`. It has to be extracted.

A bare `.pak` with no descriptor is also accepted — those go straight into
`Mods/` as a single file.

```bash
./tools/install-mod.sh ~/Downloads/SomeMod.zip   # install
./tools/install-mod.sh --check ~/Downloads/x.zip # inspect, install nothing
./tools/install-mod.sh --list                    # what is installed, with warnings
./tools/install-mod.sh --remove MyMod            # uninstall
```

Some older mods were built against game version 1.1.9 and will not load on
the full release wherever they are put.

---

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

---

## `loader_thunks.c ... vkGetPhysicalDeviceSurfaceFormatsKHR` on modern Wine

**Symptom.** With a current Wine (9/10/11) and DXVK 2.x:

```
Assertion failed!
File: dlls/winevulkan/loader_thunks.c
Expression: !status && "vkGetPhysicalDeviceSurfaceFormatsKHR"
```

**Do not** read this as "Wine is too old" — that is the *other* thunk
assertion, documented above. Check the adapter list first:

```bash
vulkaninfo --summary | grep deviceName
```

If your single GPU is listed **twice**, that is the problem:

```
deviceName = Virtio-GPU Venus (Intel(R) Xe Graphics (TGL GT2))
deviceName = Virtio-GPU Venus (Intel(R) Xe Graphics (TGL GT2))
```

**Cause.** Debian ships one architecture-neutral `virtio_icd.json`, whose
`library_path` is relative so the loader resolves it per-process. ChromeOS's
preset `VK_ICD_FILENAMES` names `virtio_icd.i686.json` and
`virtio_icd.x86_64.json`, so it is tempting to symlink *both* to it. Doing so
makes the loader open the same driver twice and enumerate one GPU as two
identical adapters, which is worth cleaning up regardless.

> **Measured result:** on the reference Chromebook, removing the duplicate
> brought `vulkaninfo` down to one adapter and DXVK's `dxgi.log` down to one
> `Found device:` line, but the `vkGetPhysicalDeviceSurfaceFormatsKHR`
> assertion was **unchanged**. A duplicate adapter is therefore *not* a
> confirmed cause of that assertion -- treat this section as hygiene, and see
> *Narrowing down a Vulkan surface crash* below for the actual procedure.

**Fix.** Keep only the `x86_64` link. The loader ignores the missing `i686`
entry, which is exactly what we want:

```bash
sudo rm -f /usr/share/vulkan/icd.d/virtio_icd.i686.json
```

`tools/enable-vulkan.sh` now creates only the `x86_64` name and removes an
i686 duplicate left by earlier versions. The launcher independently
de-duplicates `VK_ICD_FILENAMES` by resolved path at startup, so the game
still works on a system where the stray link is present.

> Verify with `vulkaninfo --summary | grep -c deviceName` -- it should print
> `1`.

### Narrowing down a Vulkan surface crash

Several of the settings this project applies were introduced to work around
bugs in *older* Wine releases:

| Setting | Added to fix | Still needed on Wine 11? |
|---|---|---|
| `dxgi.deferSurfaceCreation` | `CreateSwapChain` returning `E_FAIL` on Wine 8 | unknown -- test it |
| `MESA_VK_WSI_DEBUG=sw` | `887A0020` in `D3D11Viewport.cpp` on Wine 8 | unknown -- test it |

Both of them change *when and how the Vulkan surface is created*, which is
exactly the area a `vkGetPhysicalDeviceSurfaceFormatsKHR` assertion points at.
A workaround that was load-bearing on one Wine version can become the cause of
the next failure, so they should be re-tested after any Wine upgrade rather
than assumed.

Instead of editing a file, relaunching and reading a log six times over, run:

```bash
./tools/try-fixes.sh
```

It launches the game under each combination in turn, gives each one a time
limit so a Wine error dialog cannot stall the run, recognises the known
failure signatures, restores `dxvk.conf` afterwards and prints a summary
table. `--seconds N` changes the per-attempt time limit and `--only N` runs a
single row.

### Reading the exit code

Wine reports a Windows exit status through an 8-bit shell exit code, so the
status gets truncated. The low byte is what reaches the log:

| `rc=` | Windows status | Meaning |
|---|---|---|
| 0 | - | clean exit |
| 3 | - | Unreal fatal error: it calls `exit(3)` when `GIsCriticalError` |
| 5 | `0xC0000005` | access violation -- a crash *inside the game's own code* |
| 11 | `0xC000000B` | segmentation fault |
| 53 | `0xC0000135` | a DLL was not found |

`rc=3` and `rc=5` mean genuinely different things, and the difference is the
most useful signal in this whole project:

* **`rc=3`** -- Unreal caught the problem itself, wrote a crash report and
  exited deliberately. Read the report; it names the failing call.
* **`rc=5`** -- nobody caught it. Unreal's own exception handler never ran,
  so no report exists, and Wine prints `Exception frame is not in stack
  limits => unable to dispatch exception`. The fault is below Wine, in
  Linux-side code -- in practice the Vulkan driver.

Measured on the reference Chromebook, the two are selected by one setting:

| `MESA_VK_WSI_DEBUG=sw` | result |
|---|---|
| on | `rc=5`, no report, fault inside Linux graphics code |
| off | `rc=3`, report written, `CreateSwapChain ... E_FAIL` |

With software presentation off, Venus cannot produce a usable window
surface at all, so DXGI never gets a swap chain. With it on, the surface
works and the crash moves later and deeper. It therefore has to stay on, and
the remaining problem is the one behind it.

### Getting a backtrace

The launcher historically ran Wine with `WINEDEBUG=-all`. That is good for
speed but it also discards Wine's `err:` channel, so a missing DLL or an
access violation left nothing in the log at all. The default is now
`fixme-all`, which keeps real errors and drops only the harmless noise, and
`HN_WINEDEBUG` overrides it.

For a crash with no obvious cause:

```bash
./tools/crash-trace.sh
```

It runs the game once with `+seh,+loaddll`, then prints only the parts that
matter: failed imports, unimplemented Wine functions, the exception record
with routine C++ throws filtered out, the faulting module, and the decoded
exit code. `--quick` re-reads the previous trace without relaunching.

### Unreal writes its own crash reports

Earlier notes in this project claimed a Shipping build leaves no log. That is
true of `Saved/Logs`, but it is **not** true of crash reports. UE4 writes a
folder per crash under:

```
prefix/drive_c/users/<user>/AppData/Local/HelloNeighbor/Saved/Crashes/
```

Each `UE4CC-Windows-*` folder holds `CrashContext.runtime-xml` with the
engine's own account: crash type, error message, whether it was an assert,
the engine version, and the call stack. UE4 also copies the game log in
there, which is the one place a Shipping build's log survives.

```bash
./tools/read-crash.sh            # newest report
./tools/read-crash.sh --all      # every report
```

This is far better evidence than a Wine exit code, so read it first whenever
the game dies after the engine has started.

## Things that are NOT a fallback (do not suggest these)

**Steam for Chromebook / Borealis is gone.** Google and Valve ended the
beta on 1 January 2026, and games installed through it stopped working
on that date. It is not an alternative route for this game, and no
replacement native client has been announced.

## Untried lever: Wine's native Wayland driver

On Crostini the X11 path is long -- Wine -> winex11.drv -> Xwayland ->
sommelier -> ChromeOS Exo -- and the Venus Vulkan presentation bug we
work around with `MESA_VK_WSI_DEBUG=sw` lives in that X11 leg. Wine 11
ships a much more complete `winewayland.drv`, which talks to sommelier
directly and skips Xwayland entirely.

Wine prefers X11 whenever `DISPLAY` is set, so the Wayland driver has
never been exercised here. To try it:

    WINEPREFIX=~/.local/share/hello-neighbor/prefix \
      wine reg add 'HKCU\Software\Wine\Drivers' /v Graphics /t REG_SZ /d 'wayland,x11' /f
    env -u DISPLAY ~/.local/share/hello-neighbor/bin/hello-neighbor-launch

To undo:

    WINEPREFIX=~/.local/share/hello-neighbor/prefix \
      wine reg delete 'HKCU\Software\Wine\Drivers' /v Graphics /f

## Untried lever: CPU topology

Several Unreal Engine titles are documented on ProtonDB as failing to
start under Wine on modern Intel laptop CPUs, fixed by hiding most of
the CPU from the game with `WINE_CPU_TOPOLOGY`. The symptom matches
ours: a brief window, then the process exits with no error. Worth a
run with `WINE_CPU_TOPOLOGY=4:0,1,2,3` and without
`-USEALLAVAILABLECORES`.

## RESULT: the graphics stack is not the cause

The lavapipe run settled it. With Venus removed and the entire render
path running on the CPU, the game still exited rc=5 after 15 seconds --
the same failure, to the second.

The crash is now independent of every one of these:

  * DXVK version (2.3.1 and 1.10.3)
  * Vulkan driver (Venus on the GPU, lavapipe on the CPU)
  * Window system (winex11.drv and winewayland.drv)
  * The Venus WSI workaround, on and off
  * esync/fsync, on and off
  * Audio, on and off
  * Windowed, virtual desktop, and resolution

Something kills this process about fifteen seconds in regardless of how
it is drawing. Stop tuning the renderer.

## The decisive test: lavapipe (CPU Vulkan)

Everything so far has gone through Venus, ChromeOS's Vulkan passthrough.
Venus has never been ruled in or out. Mesa ships `lavapipe`, a complete
CPU-only Vulkan driver, as an ordinary ICD in `mesa-vulkan-drivers`, so
the whole stack can be run with Venus removed from it:

    LVP=$(ls /usr/share/vulkan/icd.d/lvp_icd*.json | head -1)
    VK_ICD_FILENAMES="$LVP" HN_VK_WSI_SW=0 hello-neighbor-launch

DXVK skips CPU adapters only while a GPU adapter is also visible; naming
lavapipe's ICD explicitly leaves no GPU adapter, so DXVK uses it. It is
extremely slow, which does not matter -- the question is only whether the
process survives past the ~15 second mark where it always dies.

  * Survives  -> Venus is the fault. Mesa 25.0.7 (bookworm-backports)
    predates the Venus WSI fixes in 25.2, and the fix is a newer Mesa,
    which on Crostini means a newer container.
  * Dies the same way -> Venus is innocent, and the fault is in Wine,
    DXVK or the game. Next lever is WINE_CPU_TOPOLOGY.

## Wine's Wayland driver: also a known-bad path

Switching to winewayland.drv changed the failure (rc=5 access violation
-> rc=3 `CreateSwapChain` `DXGI_ERROR_INVALID_CALL`) but did not fix it,
and it is a documented problem area. winewayland.drv puts two Wayland
roles on one surface, which the protocol forbids; permissive drivers
tolerate it and strict ones reject the swapchain. A separate report has
winewayland producing a compositor protocol error, then
`VK_ERROR_SURFACE_LOST_KHR`, then an access violation inside
winevulkan -- the same shape as our failure.

Note the DXVK log for the Wayland run contained no swapchain error at
all, only `readMonitorEdidFromKey: Failed to get EDID reg key size`.
DXVK logs its real reason before returning `DXGI_ERROR_INVALID_CALL`,
so the absence of a message means DXVK rejected the call before it ever
tried, i.e. on its arguments.

Revert with:

    WINEPREFIX=~/.local/share/hello-neighbor/prefix \
      wine reg delete 'HKCU\Software\Wine\Drivers' /v Graphics /f
