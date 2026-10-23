# ARENA Neighbor

## Which file

| file | state |
|---|---|
| **`ArenaNeighbor.zip`** | **1.0. Known to run.** This is the one to use. |
| `ArenaNeighbor-1.0.zip` | identical to the above, kept so the version is explicit |
| `ArenaNeighbor-1.2.zip` | 1.0 plus a rename, so the Modding menu says `AI_ArenaNeighbor` instead of `AI_Foxy_Original`. **Not yet run on hardware.** |

1.1 froze the game on load and has been removed. Its only real difference
from 1.0 was 24 bytes: six nulled class references that took away the F-key
shout, its on-screen hint, and the headlamp. One of those - almost certainly
`BP_KeyInputs`, which also calls `EnableInput` and drives the neighbour's
state during the mod's intro sequence - was load-bearing. Do not re-apply
that change without testing it one pointer at a time.

## Install

Unzip, put the `ArenaNeighbor` folder into `HelloNeighbor/Mods/` next to
`Cat_In_The_Hat`, then pick it in the Modding menu. Delete any previous
`ArenaNeighbor` folder first.

**Keep `Cat_In_The_Hat` installed** - this mod uses its model, animations and
voice, referenced by name. `FoxyReignited` is not needed and can be deleted.

## What works (confirmed on hardware)

- the Cat in the Hat as the Neighbour, with working sight
- chase speed 5500, walking and investigating 600
- doors broken through while chasing
- the Cat's chase music, every chase
- cameras, buckets, glue, vacuum cleaner. No tomatoes

## Known, not fixed

- the Modding menu lists him as `AI_Foxy_Original` (1.2 addresses this, untested)
- a second entry, `AI_Foxy_Nightmare`, sits above him. Deleting the asset is
  not enough on its own - it is also listed in the mod's `AssetRegistry.bin`,
  and a menu entry pointing at a missing file is worse than one that works
- F still shouts "HEY" and shows a hint
- no catch animation or sound

## Credits

- **FoxyReignited** by **Sdalt** - the Neighbour logic, including door breaking
- **Cat in the Hat** by **Endersteve8479** - model, animations, voice
- Retuned by ARENA

Build notes and the reasoning behind each change are in `../README.md`.
