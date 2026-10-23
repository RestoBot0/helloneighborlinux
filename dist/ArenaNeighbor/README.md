# ARENA Neighbor

## Which file

| file | state |
|---|---|
| **`ArenaNeighbor.zip`** | **1.8.** Always use this one - it tracks the newest good build. |
| `ArenaNeighbor-1.8.zip` | identical to the above, kept so the version is explicit |
| `ArenaNeighbor-1.7.zip` | previous; grab still used the base game's animation |
| `ArenaNeighbor-1.5.zip` | previous; scream was intermittent and the laugh never landed with it |
| `ArenaNeighbor-1.6-catanim.zip` | the animation experiment on its own; 1.7 includes it |
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

### Why the scream and the laugh never landed together

They are on two different triggers and only one of them is reliable.

The laugh is `DieSound`, which fires on every catch. The scream is
`ScreamRandom.Play()` at raw 7769, which sits behind
`JumpIfNot AttackSound?`. That flag is read in exactly one place - this gate -
and the state machine writes it `True` in one branch and `False` in four
others, so the scream only happened on some catches. That is the whole reason
one or the other kept going missing between builds; the wiring never changed.

All five writes are now `True`, so the scream is unconditional and the two
start together. `EX_False` to `EX_True` is a single byte, identical on disk
and at runtime.

### Why the idle whistle was silent

`ReceiveBeginPlay` starts a looping timer on `CustomEvent` with an interval of
**0.05 seconds** - twenty ticks a second - and the idle block lives inside it:

    if Idle?  and  RandomIntegerInRange(1, 2) == 1:   Audio.Play(0.0)

so while he was idle that `Play()` fired roughly ten times a second. Calling
`Play` on an `AudioComponent` restarts it, so the whistle never got past its
first few milliseconds and nothing was audible. Widening the range to 1-in-200
gives about one whistle every ten seconds instead. Four bytes.

### The grab is three fields, not one

This was my mistake and it took far too long to find. The neighbour's grab is
not a single animation slot. Stock Foxy points **three** fields at
`Foxy_Jumpscare_Anim`:

| field | what it is |
|---|---|
| `Catch` | the catch |
| `Choke` | the grab itself |
| `BedLookTake` | dragged out from under the bed |

The build only set `Catch` and renamed the other two to `HNX_Removed`, which
makes UE4 skip the tag and inherit the parent's value - the base game's
animation. So the grab kept playing the stock Neighbour's animation no matter
what `Catch` was set to. All three now point at `cat_grabbed_2`.

That also settles the sound: `cat_grabbed_2` carries both
`AnimNotify_PlaySound` entries, the scream and the laugh, so playing it starts
them together exactly as the original mod does.

### No delay on the catch

After `DisableMovement` the sequence waited 0.3s and then 3s. Those existed to
hold Foxy's full-screen jumpscare image, which is gone, so they had become a
dead freeze where nothing happened. Both are now 0.

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

- the neighbour's jump grunt is the base game's, as it is in the original
  Cat mod too
- the neighbour's jump grunt is the base game's. The original Cat mod has
  this too - it does not override the jump animations either
- F still shouts "HEY" and shows a hint. Removing it froze the game in 1.1
  and has not been retried

## Credits

- **FoxyReignited** by **Sdalt** - the Neighbour logic, including door breaking
- **Cat in the Hat** by **Endersteve8479** - model, animations, voice
- Retuned by ARENA

Build notes and the reasoning behind each change are in `../README.md`.
