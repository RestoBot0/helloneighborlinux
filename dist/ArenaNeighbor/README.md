# ARENA Neighbor

`ArenaNeighbor.zip` — 25.8 MB — the finished mod, ready to drop in. No scripts,
no patching, no terminal.

## Install

1. Unzip it.
2. Put the `ArenaNeighbor` folder into your game's `HelloNeighbor/Mods/` folder,
   next to `Cat_In_The_Hat`.
3. Start the game, open the Modding menu, pick **ARENA Neighbor**.

**Keep `Cat_In_The_Hat` installed.** This mod uses the Cat's model, its
animations and its voice, and points at them by name. Without it you get an
invisible, silent Neighbour. You do not need `FoxyReignited` any more — this
replaces it, and you can delete that folder.

## What he does

| | |
|---|---|
| body | the Cat in the Hat |
| sight | normal Neighbour eyes - he can actually see you |
| chase speed | 5500, the Cat mod's own number |
| walking / investigating | 600 |
| doors | walks up and opens them normally when investigating, smashes through them when chasing |
| traps | cameras, buckets, glue, vacuum cleaner, stock bear traps. No tomatoes |
| voice | the Cat's scream, laugh and idle whistle |
| music | the Cat's panic cue, every chase |

Nothing of Foxy's is left on purpose: no Foxy sounds or animations, no
jumpscare overlay, no camera flash, no "HEY", no headlamp stun, no nightmare
mode, no 3500 speed.

## Credits

- **FoxyReignited** by **Sdalt** — the Neighbour logic this is built on, including
  the door breaking.
- **Cat in the Hat** by **Endersteve8479** — the model, animations and voice.
- Retuned and reassembled by ARENA.

Please keep those two credits with it if you pass it on.

## How it was made

Built from the stock FoxyReignited pak by `tools/catbody-build.py`, then
renamed end to end by `tools/rename-mod.py`. Both are in this repo and both
refuse to write a file that fails their own checks.

The build is described in full in `../README.md`. The short version is that
`AI_Foxy_Original` is edited in place — never subclassed, because a cooked
Blueprint class inherits its parent's *data* but runs none of its *code*.

### The rename

`FoxyReignited` and `ArenaNeighbor` are both 13 characters, which is not a
coincidence. The mod name is baked into 1,731 places: package paths inside the
assets, the asset registry, and the pak's file list. Those strings are all
length-prefixed, so a name of a different length would shift thousands of
offsets. Same length means every replacement is a straight byte swap.

What the renamer has to repair afterwards:

- **the FName hashes.** Every name in a cooked package and in an
  `AssetRegistry.bin` is stored as `<int32 length><chars><uint16 Strihash>
  <uint16 StrCrc32>`. Swapping the text leaves both hashes describing the old
  string. Epic's docs say they are "not used anymore but recalculated on save",
  so stale ones are survivable, but there is no reason to ship a file whose own
  checksums disagree with itself. 1,366 were recomputed.
- **all three SHA1 layers in the pak** — per file, the copy in each entry
  header, and the index hash.

Verified afterwards: 25,681 names re-walked from scratch with 0 stale hashes
and 0 unreadable tables, 0 occurrences of the old name anywhere in any path or
any file, all 205 content and header hashes good, index hash good, and all 203
packages still parse with every export inside the file.

Against the pre-rename build, `AI_Foxy_Original.uasset` differs in 969 bytes
across 114 runs, and every single run is inside the name table. The ubergraph
is untouched: 3,592 statements, runtime length 25,027, the door break intact.
