# ARENA Neighbor, built into the Cat mod's own pak

`Cat_In_The_Hat-ARENA.zip` - 6.4 MB. This is the other way round from
everything in `../ArenaNeighbor/`: instead of putting the Cat's body into
Foxy's pak, Foxy's **brain** goes into the Cat's pak.

## Install

1. Unzip. Replace your existing `Cat_In_The_Hat` folder in
   `HelloNeighbor/Mods/` with this one.
2. **Keep `FoxyReignited` installed, stock.** The brain references 56 assets
   that live in the Foxy pak - door-break blueprints, traps, materials. All 56
   were checked to resolve.
3. In the Modding menu the Cat mod now offers **two** neighbours:
   - `BP_Cat_hat` - the original Cat, untouched
   - `ArenaAI` - the Cat body with Foxy's brain

   Pick **ArenaAI**.

You can delete the `ArenaNeighbor` folder if you have it.

## What this is

`AI_Foxy_Original` is copied into the Cat pak at
`Mods/Cat_In_The_Hat/Content/Content/ArenaAI.uasset`, and its package path is
swapped from `/FoxyReignited/AI_Foxy_Original` to
`/Cat_In_The_Hat/Content/ArenaAI`. Those are both exactly 31 characters, so
the swap is a byte-for-byte replacement with the two FName hashes recomputed -
no offsets move.

The three problems this arrangement had before are all fixed:

| problem | fix |
|---|---|
| Foxy's scream | `ScreamRandom.Sound` -> the Cat's `ignited-bonnie-jumpscare-remake` |
| run speed | `m_fRun` and `MaxWalkSpeed` 3500 -> 5500, in the CDO *and* in the ubergraph init block that overwrites it |
| vision | Foxy's `ScannerComponent` sits 285 cm up, which left the Cat blind. The offset is dropped so he uses the stock position |

Everything else from the `ArenaNeighbor` line comes along: Cat mesh and voice,
600 walk so he opens doors instead of barging them, door breaking while
chasing, chase music every time, traps minus tomato, no F-key shout.

## The original Cat mod is still in here

`BP_Cat_hat.uasset` is byte-identical to the one shipped by Endersteve8479 -
nothing was overwritten. The only changed file is `AssetRegistry.bin`, which
gains one record so the menu can see `ArenaAI`.

`tools/registry-trim.py` grew a `clone_record` for that: it copies an existing
record, repoints its five FNames, rewrites the `GeneratedClass` tag and
appends any new strings to the registry's name table. Rebuilding a registry
with no changes still reproduces the original byte for byte, which is what
makes it trustworthy.

## Credits

- **FoxyReignited** by **Sdalt** - the Neighbour logic
- **Cat in the Hat** by **Endersteve8479** - model, animations, voice
- Retuned by ARENA
