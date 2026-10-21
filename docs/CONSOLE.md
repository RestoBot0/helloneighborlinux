# Unlocking the UE4 developer console

> ### ⛔ TESTED ON HARDWARE, 21 Oct 2026 — IT DOES NOT WORK
>
> `~` and `F1` were both tried on the retail full game. Neither opens anything.
> **This is not a configuration problem and no `.ini` edit can fix it.** Read
> "Why it can never work" below before spending any more time here.

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

## Why it can never work

Retail *Hello Neighbor* is a UE4 **Shipping** build. Unreal wraps the console's
construction in `#if ALLOW_CONSOLE`, which is `0` for Shipping — so the console
object is never created and the code is **not present in the `.exe` at all**. It
is removed, not hidden, which is why no setting can reach it:

```cpp
// Engine/Source/Runtime/Engine/Private/GameViewportClient.cpp
#if ALLOW_CONSOLE
    ViewportConsole = NewObject<UConsole>(this, GetOuterUEngine()->ConsoleClass);
    GLog->AddOutputDevice(ViewportConsole);
#endif // !UE_BUILD_SHIPPING
```

The same `#if` also strips the `fly`, `walk` and `ghost` cheats, so even a
re-injected console could not run them.

`ALLOW_CONSOLE_IN_SHIPPING` is a **compile-time define in `Build.h`**, not a
console variable — putting it in an `.ini` does nothing. (This is also why the
`[ConsoleVariables]` section was deliberately removed from `config/Engine.ini`;
see the comment there.)

Sources:

- <https://fearlessrevolution.com/viewtopic.php?t=14710> — the engine source above, and the note that `fly`/`walk`/`ghost` go with it
- <https://forums.unrealengine.com/t/enable-console-in-shipping-build/353468> — `ALLOW_CONSOLE_IN_SHIPPING` requires a source engine rebuild
- <https://steamcommunity.com/app/521890/discussions/0/154641879448582795/> — Hello Neighbor players, bluntly: *"THERE ARE NO CONSOLE COMMANDS IN THE FULL RELEASE"*
- <https://hello-neighbor.fandom.com/wiki/Command_Console> — *"GreenHouseM13 created a command console for the full game, however it is a custom one and doesn't resemble the original UE4 command bar"*

The `ConsoleKey` bindings and the `-console` flag are **left in place anyway**:
they are harmless, and they genuinely do work on the Hello Neighbor Alphas and
on many other UE4 titles. They will simply never do anything on this build.

## What exists instead

| Route | What you actually get |
|---|---|
| **Green cube easter egg** — start Act 1 and touch nothing for 10 real minutes | A fake console that only responds while you stand inside the cube, and only to the Error World strings (`AI_errorDumping=0`, `PlayerSpeed=`, `GameQuit`) |
| **GreenHouseM13's Console Enabler** — community mod, opens with `U` | A custom console with working cheats, including a **Change Speed** panel: player default 900, Neighbor default 600 |
| **Universal UE4 Unlocker** | A Windows DLL injector that re-adds a console to many UE4 games. **Untested under Wine/Crostini.** |

Everything in the rest of this file therefore applies **only** to the Alphas, or
after installing one of the routes above.

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
