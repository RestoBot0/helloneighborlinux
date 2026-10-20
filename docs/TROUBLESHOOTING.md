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
