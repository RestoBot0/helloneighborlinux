# ARENA Neighbor

## Which file

| file | state |
|---|---|
| **`ArenaNeighbor.zip`** | **1.5.** Always use this one - it tracks the newest good build. |
| `ArenaNeighbor-1.5.zip` | identical to the above, kept so the version is explicit |
| `ArenaNeighbor-1.6-catanim.zip` | **experiment, please test.** 1.5 with BP_Cat_hat's exact animation setup. May break anything played as a montage |
| `ArenaNeighbor-1.4.zip` | runs; scream works, but no laugh and no idle whistle |
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
| catches you | `ScreamRandom` -> `ignited-bonnie-jumpscare-remake` (the scream) **and** `DieSound` -> `jump_Cue` (the laugh over the top). Those are exactly the two sounds `cat_grabbed_2` would have fired |

`ScreamRandom.Play()` sits at raw 7769, gated on `AttackSound?` and followed
immediately by `DisableMovement` - that is the catch.

### Why the idle whistle was silent

`ReceiveBeginPlay` starts a looping timer on `CustomEvent` with an interval of
**0.05 seconds** - twenty ticks a second - and the idle block lives inside it:

    if Idle?  and  RandomIntegerInRange(1, 2) == 1:   Audio.Play(0.0)

so while he was idle that `Play()` fired roughly ten times a second. Calling
`Play` on an `AudioComponent` restarts it, so the whistle never got past its
first few milliseconds and nothing was audible. Widening the range to 1-in-200
gives about one whistle every ten seconds instead. Four bytes.

### What the original Cat mod actually does

Taken apart in full. `BP_Cat_hat` has **no bytecode at all** - not one function
with code. It is a pure data Blueprint, so everything the Cat does is the base
game's own neighbour behaviour driven by what it sets:

| | |
|---|---|
| `Animations.BaseBlueprintClass` | `CATAnimBlueprint_C` |
| `Animations` | Fall, PlayerInHome, Catch, BedLookStart, SlipAndFall, LookAround, Afraid |
| `Sounds` | Sleep `neighbor_snore_1_Cue`, StepSound `sosed_steps` |
| `attack_sound.Sound` | `panic_Cue` |
| `SoundStruck` | `secretsound_Cue` |
| speeds | 600 / 600 / 5500 |
| jumping | `JumpMaxHoldTime` 0.5, `JumpMaxCount` 3 |
| `CharacterMesh0` | `SkeletalMesh` and `AttachParent` only - **it never sets `AnimClass`** |

That last row is the important one. The Cat mod leaves the mesh's AnimClass
alone and lets the game apply `Animations.BaseBlueprintClass`. This build
forces `SosedAnimBlueprint_C` into both, because `CATAnimBlueprint` has no
Slot node - there is no `AnimNode_Slot` and no name containing "Slot" except
`SlotIndex` - so anything played as a montage renders nothing through it.

`-catanim` reproduces the Cat mod's setup exactly, to find out whether the
catch animation depends on it. Build it with
`catbody-build.py in.uasset out.uasset --cat-animbp`.

The jump grunt is not something this build introduced: `BP_Cat_hat` has no
`Jump_Start` or `Jump_Loop` override either, so it inherits the base game's
jump animation and grunt the same way - and it sets `JumpMaxCount` to 3, so
the Cat jumps a lot.

## What works (confirmed on hardware)

- the Modding menu names him `AI_ArenaNeighbor` (1.2)
- the Cat in the Hat as the Neighbour, with working sight
- chase speed 5500, walking and investigating 600
- doors broken through while chasing
- the Cat's chase music, every chase
- the Nightmare entry gone from the menu (1.3)
- cameras, buckets, glue, vacuum cleaner. No tomatoes

## Known, not fixed

- the catch animation does not play, so the laugh baked into `cat_grabbed_2`
  as its second notify is never heard. `LookAround` does play, so animations
  in general are fine - it is the catch specifically. `-catanim` is the test
  for whether the Cat's own AnimBP is what the catch needs
- `DieSound` is not the catch sound. Pointing it at the laugh in 1.5 changed
  nothing, so getting caught does not go through it
- the neighbour's jump grunt is the base game's. The original Cat mod has
  this too - it does not override the jump animations either
- F still shouts "HEY" and shows a hint. Removing it froze the game in 1.1
  and has not been retried

## Credits

- **FoxyReignited** by **Sdalt** - the Neighbour logic, including door breaking
- **Cat in the Hat** by **Endersteve8479** - model, animations, voice
- Retuned by ARENA

Build notes and the reasoning behind each change are in `../README.md`.
