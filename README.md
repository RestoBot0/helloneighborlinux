# Hello Neighbor on ChromeOS (Crostini)

Turns a Windows copy of *Hello Neighbor* into a normal, clickable ChromeOS app:
one icon in your launcher/shelf, no terminal, tuned for 60+ FPS on Intel Iris Xe.

**Target machine:** Chromebook · 12th gen Intel Core i5 · Intel Iris Xe · 8 GB RAM · Debian 12 (Crostini)

---

## TL;DR — what you do

```bash
# 1. clone this repo inside your Crostini terminal
git clone https://github.com/RestoBot0/helloneighborlinux.git
cd helloneighborlinux

# 2. point it at your .rar and walk away
./install.sh --rar ~/Downloads/HelloNeighbor.rar
```

Then press the **Search/Everything** key, type `Hello`, right-click → **Pin to shelf**. Done.

> **10th-gen Intel CPU or newer?** The launcher already handles it. The game
> ships an old OpenSSL that mis-detects the SHA-NI instructions those CPUs
> introduced and crashes about fifteen seconds in, with no crash report. The
> launcher exports tinyBuild's documented workaround
> (`OPENSSL_ia32cap=:~0x20000000`) on every run. Full write-up:
> [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

---

## Important: the archive stays on your Chromebook

The game is **not** uploaded anywhere, and it does not need to be.

I verified that this build environment cannot reach GitHub Release assets — they
302-redirect to `release-assets.githubusercontent.com`, which is outside the
network allowlist, so both `curl` and `gh release download` fail:

| Host | Reachable |
|---|---|
| `github.com` (git clone/push) | ✅ |
| `api.github.com` | ✅ |
| `codeload.github.com` | ✅ |
| `release-assets.githubusercontent.com` | ❌ **blocked** |

That turns out not to matter, because uploading 2 GB up and 5 GB back down would
be the slow way to do this anyway. Your Chromebook has the archive and an SSD.
`install.sh` unpacks it **locally**, at local speed.

The only thing worth sending over is a **file listing** (~20 KB of text):

```bash
./tools/make-manifest.sh ~/Downloads/HelloNeighbor.rar
git add manifest.txt && git commit -m "archive manifest" && git push
```

That tells me the exact build, folder layout, UE4 version and whether there's a
`Plugins/` or `Mods/` folder, so the configs can be matched to your actual copy.
It lists names and sizes only — no game data.

---

## What gets installed where

```
~/.local/share/hello-neighbor/
├── game/                 the unpacked game
├── prefix/               the Wine prefix (isolated, nothing else uses it)
│   └── drive_c/users/<you>/AppData/Local/HelloNeighbor/Saved/Config/
│       └── WindowsNoEditor/{Engine,Scalability,GameUserSettings,Input}.ini
├── bin/hello-neighbor-launch     the hidden launch wrapper
├── cache/{dxvk,mesa}             shader caches
├── logs/                         last 10 launches
├── launcher.conf                 your settings — edit this, no reinstall needed
└── dxvk.conf

~/.local/share/applications/hello-neighbor.desktop    the shelf entry
~/.local/share/icons/hicolor/*/apps/hello-neighbor.png
```

Everything is under `~/.local/share`. Nothing is installed system-wide except
Wine itself. `./uninstall.sh --all` removes the lot.

---

## Right-click menu on the shelf icon

The `.desktop` entry ships four actions, so the common fixes never need a terminal:

| Action | What it does |
|---|---|
| **Play in a window** | windowed mode |
| **Safe mode (OpenGL / DX10)** | the maximum-compatibility path — try this first if it won't start |
| **Force quit the game** | kills the game and the Wine server |
| **Open the log folder** | jumps straight to the logs |

---

## The performance tuning, and why

Hello Neighbor is Unreal Engine 4. The settings in `config/` are not a generic
"low preset" — they target the three things that specifically hurt on Crostini:

**1. Shadows (the big one).** The neighbour's house is lit by a lot of dynamic
point lights, and dynamic shadow rendering is where an iGPU behind a virtualised
GPU falls over. Shadow map resolution is capped at 512, cascades at 2, and
distance scaled to 0.55.

**2. Exclusive fullscreen is avoided entirely.** `FullscreenMode=1` (borderless).
Exclusive fullscreen asks Wine to perform a real display mode change; there is no
real display inside Crostini, and the usual result is a black screen with audio
playing. This is the single most common "the game doesn't work" cause, and it's
pre-empted.

**3. The first-launch hardware benchmark is disabled.** `LastGPUBenchmarkResult=-1`
stops UE4 auto-detecting quality. Left on, it misreads the virtio GPU and happily
sets everything to Epic on first boot, undoing all of the above.

Plus: 85% screen percentage with sharpening, FXAA instead of TAA (cheaper, and no
ghosting once you're upscaling), motion blur and depth of field off, a 1024 MB
texture streaming pool sized for 8 GB of shared RAM, and HZB occlusion culling
(hardware occlusion queries stall badly under both DXVK and WineD3D).

**Audio:** `PULSE_LATENCY_MSEC=60`. The default 20 ms crackles through the ChromeOS
audio bridge; 60 ms is imperceptible as lag but silences it completely.

---

## Graphics backend selection

The launcher detects what's available rather than assuming:

- **Vulkan present (Venus passthrough working)** → DXVK, game runs DirectX 11.
- **No usable Vulkan** → WineD3D over OpenGL/VirGL, and the game is launched with
  `-dx10 -sm4` to drop to Shader Model 4. SM4 shaders are materially cheaper, and
  WineD3D's translation of SM5 is where most of the stuttering comes from.

Override any time with `--vk` / `--gl` / `--safe`, or set `FORCE_BACKEND` in
`launcher.conf`.

---

## Developer console

Bound to **both `~` and `F1`** (see [docs/CONSOLE.md](docs/CONSOLE.md)).

Two keys because Crostini apps get their input through Sommelier/Wayland, and on
some keyboard layouts the `~` keypress is swallowed before Wine ever sees it.
If `~` does nothing, press `F1`.

The launcher also passes `-console`. Be aware: if this particular build compiled
the console out (UE4 strips it from Shipping configurations unless the developer
opted in), no `.ini` edit can bring it back — that case needs a separate unlocker,
which is covered in the doc.

---

## Changing settings later

Edit `~/.local/share/hello-neighbor/launcher.conf`:

```bash
RES_W=1600
RES_H=900
FORCE_BACKEND=""     # "" (auto) | dxvk | wined3d
WINDOWED=0
ENABLE_CONSOLE=1
EXTRA_GAME_ARGS=""
```

No reinstall needed — it's read on every launch.

---

## Repo layout

```
install.sh                     main installer (run on the Chromebook)
uninstall.sh                   clean removal
config/Engine.ini              UE4 render tuning
config/Scalability.ini         quality presets (stops the options menu undoing things)
config/GameUserSettings.ini    resolution, borderless, benchmark disable
config/Input.ini               console keys, mouse smoothing off
launcher/hello-neighbor-launch.sh   the hidden wrapper
launcher/hello-neighbor.desktop.in  shelf entry template
launcher/hello-neighbor.png         icon
tools/make-manifest.sh         describe the archive without extracting it
docs/CONSOLE.md                console unlock + useful commands
docs/TROUBLESHOOTING.md        symptom → fix
```

---

## Testing status

| Verified in CI sandbox | |
|---|---|
| All four shell scripts pass `bash -n` | ✅ |
| `install.sh` end-to-end against a mock retail tree | ✅ |
| Resolution substitution at 1280x720 / 1600x900 / 1920x1080 | ✅ |
| `.desktop` spec-conformance, all 4 actions resolve | ✅ |
| Launcher: auto / `--safe` / `--vk` / `--windowed` / `--kill` / `%U` | ✅ |
| Icon renders at all 8 installed sizes | ✅ |

**Not yet verified:** anything requiring real Wine, a real GPU or the real game —
there's no Wine, no GPU and no game data in the build sandbox. The FPS targets are
reasoned from the hardware, not measured. First real run on your Chromebook is the
actual test, and the logs in `~/.local/share/hello-neighbor/logs/` will say exactly
what happened.

---

## Legal

This repo contains **no game content** — only configuration, scripts and an icon.
It assumes you own your copy of Hello Neighbor. *Hello Neighbor* is © tinyBuild /
Dynamic Pixels.
