# ARENA Neighbor

## Which file

| file | state |
|---|---|
| **`ArenaNeighbor.zip`** | **1.4.** Always use this one - it tracks the newest good build. |
| `ArenaNeighbor-1.4.zip` | identical to the above, kept so the version is explicit |
| `ArenaNeighbor-1.3.zip` | runs, Nightmare gone, but the catch is silent |
| `ArenaNeighbor-1.2.zip` | confirmed running on hardware; still shows the Nightmare entry |
| `ArenaNeighbor-1.0.zip` | the previous build. Also runs, but the Modding menu calls him `AI_Foxy_Original` |

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

## Sound, and where each one comes from (1.4)

| | |
|---|---|
| chase music | `attack_sound` -> `panic_Cue` |
| idle whistle | `Audio` -> `Cat_Whistling_Bored_Talking_Cue` |
| spots you | `Audio2` -> `pieceofcake_Cue`, was still `Foxy_Spot_Cue` |
| catches you | `ScreamRandom` -> `ignited-bonnie-jumpscare-remake`, was still `Foxy_ScreamRandom_Cue`; and `DieSound`, which the mod had set to `Clear_Cue` i.e. silence |

`ScreamRandom.Play()` sits at raw 7769, gated on `AttackSound?` and followed
immediately by `DisableMovement` - that is the catch. `cat_grabbed_2` also
carries two `AnimNotify_PlaySound` entries of its own, so if the animation
plays the sound comes with it; wiring the component too means it fires either
way.

## What works (confirmed on hardware)

- the Modding menu names him `AI_ArenaNeighbor` (1.2)
- the Cat in the Hat as the Neighbour, with working sight
- chase speed 5500, walking and investigating 600
- doors broken through while chasing
- the Cat's chase music, every chase
- the Nightmare entry gone from the menu (1.3)
- cameras, buckets, glue, vacuum cleaner. No tomatoes

## Known, not fixed

- the catch *animation* may still be the base game's rather than the Cat's.
  `Animations.Catch` is set to `cat_grabbed_2`, but it has not been confirmed
  playing. 1.4 wires the scream to the audio component as well, so the sound
  no longer depends on the animation
- F still shouts "HEY" and shows a hint. Removing it froze the game in 1.1
  and has not been retried

## Credits

- **FoxyReignited** by **Sdalt** - the Neighbour logic, including door breaking
- **Cat in the Hat** by **Endersteve8479** - model, animations, voice
- Retuned by ARENA

Build notes and the reasoning behind each change are in `../README.md`.
