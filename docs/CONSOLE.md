# Unlocking the UE4 developer console

## How it's set up here

Three things are configured for you:

1. **`Input.ini` / `Engine.ini`** bind the console to two keys:
   ```ini
   [/Script/Engine.InputSettings]
   ConsoleKey=Tilde
   +ConsoleKeys=Tilde
   +ConsoleKeys=F1
   ```
2. **The launcher passes `-console`** on the command line.
3. **`[ConsoleVariables] AllowConsoleInShipping=1`** is set in `Engine.ini`.

Press **`~`** (tilde, above Tab) or **`F1`** in game. One tap opens the small
single-line console at the bottom; a second tap opens the full scrollback.

## Why two keys?

Crostini apps receive input through Sommelier → Wayland → Wine. On several
keyboard layouts — UK layouts especially, where `~` is a shifted key — the
keypress is consumed before Wine ever sees it. `F1` is bound as a plain,
unshifted fallback that always arrives.

## Being straight with you about shipping builds

Unreal Engine 4 **compiles the console out** of Shipping configurations unless
the developer explicitly opted into keeping it. If tinyBuild shipped Hello
Neighbor that way, then **no `.ini` edit and no launch flag can bring it back** —
the code simply isn't in the binary. `AllowConsoleInShipping` is read by some
builds and ignored by others.

So: try the above first. It costs nothing and works on a good number of UE4
retail titles. If both keys do nothing, you need a runtime unlocker that injects
the console back in — the community one is
[`UE4-console-unlocker`](https://github.com/Lyall) / "Universal UE4 Console
Unlocker" (search that exact phrase; it's a DLL you drop next to the shipping
exe). Under Wine you'd add it via `WINEDLLOVERRIDES`.

Tell me if the keys do nothing and I'll wire the unlocker into the launcher
properly.

## Useful commands once it opens

### Diagnosing performance
| Command | What it shows |
|---|---|
| `stat fps` | frame rate + frame time |
| `stat unit` | **the important one** — splits Frame / Game / Draw / GPU |
| `stat gpu` | per-pass GPU cost |
| `stat memory` | memory use |
| `r.ScreenPercentage 70` | drop render resolution live, watch the FPS move |

**How to read `stat unit`:** whichever of *Game* (CPU logic), *Draw* (CPU render
thread) or *GPU* is closest to *Frame* is your bottleneck. On Crostini it's
usually **Draw** — that's the Wine/translation overhead, and it's why lowering
graphics settings sometimes doesn't help. If Draw is the limit, lower the
*resolution* rather than the effects.

### Live tuning (try before editing the .ini)
```
r.ScreenPercentage 70        lower = faster, 50..100
r.Shadow.MaxResolution 256   shadows are the biggest single cost
r.ShadowQuality 0            shadows off entirely
sg.PostProcessQuality 0
sg.EffectsQuality 0
r.VSync 0
t.MaxFPS 60
```

### Game commands
| Command | Effect |
|---|---|
| `god` | invulnerability |
| `ghost` | no-clip (fly through walls) |
| `walk` | back to normal from `ghost` |
| `slomo 0.5` | half speed (`slomo 1` resets) |
| `teleport` | jump to where you're looking |
| `showdebug ai` | AI state — handy for watching the neighbour's logic |
| `stat levels` | streaming levels currently loaded |
| `quit` | clean exit |

> Hello Neighbor's AI is the whole game. `showdebug ai` plus `slomo 0.3` is
> genuinely interesting to watch — you can see it learn your routes.

### Making a change permanent

Anything that works in the console goes in
`~/.local/share/hello-neighbor/prefix/drive_c/users/<you>/AppData/Local/HelloNeighbor/Saved/Config/WindowsNoEditor/Engine.ini`
under `[SystemSettings]`, without the leading `r.`/`sg.` changing:

```ini
[SystemSettings]
r.ScreenPercentage=70
```
