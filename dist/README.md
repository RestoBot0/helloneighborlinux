# dist - built mod files

## catbody/ - the Cat-bodied Neighbour (current)

`AI_Foxy_Original.uasset` replaces the same file inside `FoxyReignited.pak`.
`APPLY.sh` rebuilds the pak with it, keeping `<pak>.bak` so repeat runs are
safe and reversible.

In the game's Modding menu pick **FoxyReignited**, not Cat_In_The_Hat. Both
mods must be installed - the Cat pak supplies the mesh and the sounds that
this asset points at.

Built by `tools/catbody-build.py` from the stock asset, entirely by name
lookup. What it changes and why is documented in that script's docstring; the
short version:

| change | reason |
| --- | --- |
| `CharacterMesh0.SkeletalMesh` -> `Cat_in_the_hat_rig` | the Cat mesh is rigged to the stock `neighbour_lowpoly_Skeleton`, so it is a straight swap |
| `CharacterMesh0.AnimClass` -> `SosedAnimBlueprint_C` | the Cat mod's `CATAnimBlueprint` has **no** `AnimNode_Slot`/`DefaultSlot`, and a montage with no matching slot in the AnimGraph silently renders nothing - that is why the Cat could not open doors and most of its actions were missing |
| `Animations` struct | 21 of the 30 slots held Foxy animations (wrong skeleton, so nothing played). Each one now drops its tag and falls back to BP_Sosed's stock Neighbour animation, except the slots where the Cat mod ships a real animation: `Catch` -> `cat_grabbed_2`, `BedLookStart` -> `cat_lookunder_bed_start`, `LookAround` -> `Cat_Anim_rig_LookAround`, `Fall`/`SlipAndFall` -> `Cat_Anim_rig_fall_run`, `Afraid` -> `Cat_Anim_rig_spotted`. **The Cat's entire voice is AnimNotifies inside those animations** - the scream, the laugh, the idle whistle - so this is the only way to hear it |
| 19 `EX_DynamicCast` operands in `ReceiveBeginPlay` | BeginPlay swept the level and overwrote the animation every sofa, bath, sink, bed, ladder, TV, chair, cupboard, door and bear trap asks the Neighbour to play, pointing them all at Foxy animations. Each block sits behind a cast + `PopExecutionFlowIfNot`, so repointing the cast's class at `WG_SdaltSpam_C` (a widget - no actor can ever be one) makes the cast fail and the block is skipped down the path the game already takes for every non-matching actor. The operand is a 4-byte `FPackageIndex`, identical in size serialised and at runtime, so no jump offset moves. The second `Door_inward_C` cast - the door break - and both `BP_Human_C` casts are deliberately left alone |
| `ScannerComponent.RelativeLocation` / `.RelativeRotation` dropped | this component is the Neighbour's **sight**. Foxy parks it at z = 285 cm with a 90 degree yaw to suit his tall animatronic head; the Cat is roughly 180 cm, so the sight traces started about a metre above its head and ran into the ceiling - he could hear but not see. `BP_Cat_hat` sets only `AttachParent`, so dropping both restores the Cat mod's setup exactly. This is also the likely reason the chase music was rare: `attack_sound` only plays in the attack state, which he could hardly ever reach |
| `CharacterMesh0.RelativeLocation` dropped | Foxy nudges the mesh 10 cm back and 5.5 cm right to line his own model up with the capsule; on the Cat that just desyncs the body from its collision - "the hitbox is different" |
| `attack_sound` / `Audio` `RelativeLocation` dropped | both emitters were placed at Foxy's head height (159 cm and 250 cm up), i.e. above the Cat, which hurts 3D attenuation |
| `SoundStruck` -> Cat `secretsound_Cue` | matches what `BP_Cat_hat` does |
| `attack_sound.Sound` -> Cat `panic_Cue` | the chase music; same component the Cat mod uses for it |
| `Audio.Sound` -> `Cat_Whistling_Bored_Talking_Cue` | replaces Foxy's `IdleNoises_Cue`, the mechanical whirring |
| `ClassBearTrap` tag removed | falls back to the stock `BP_Trap_C` instead of `BP_FoxyTrap_C` |
| `Jumpscared()` body replaced with a bare return | that event was `Delay(1s)` then `Create(WG_SdaltSpam_C)` + `AddToViewport`. The "HEY" shout is a different event (`IntroWidgets` -> `WG_FshoutFR_C`) and is left alone |
| speeds 600 / 600 / 5500, traps all on except tomato | the requested spec |
| both `BP_Human_C` casts kept alive | these two blocks set the player's `DieSound` and `SosedNearSound1/2/3` to `Clear_Cue`, i.e. they mute **the base game's own catch sound and proximity chase music**. Killing them along with the animation blocks let Hello Neighbor's default audio play on top of the Cat's, which is why the Cat's chase music and catch scream could not be heard. The second block also flattens the base game's "he is close" post-process; that comes along with it and cannot be separated out, see the warning below |
| runtime `m_fRun` / `MaxWalkSpeed` 3500 -> 5500 | the CDO numbers are only half the story: the ubergraph writes speeds at runtime and those writes win. Foxy's 3500 was overriding the Cat mod's 5500 |
| runtime `m_fWalk` 2100 -> 600, and 291.67 -> 600 | **this is the door fix.** On entering the hunt state the ubergraph sets `m_fWalk = 2100`, so when he goes to investigate a noise he arrives at 2100 instead of the Cat's 600. Door opening is animation-driven and takes time, so at that speed he just barges into the door - and the break is gated on `Attack?`, so nothing happens. The mod author says as much on the Workshop page: he "tends to break through doors **when attacking you**" and "shouldn't get stuck on doors **as much** as the other animatronics". At 600 the normal open animation gets its chance |
| attack music dice roll `RandomIntegerInRange(0, 3) == 2` -> `(2, 2)` | entering the attack state only started `attack_sound` on a 1-in-4 roll, which is the "chase music only appears rarely" report. Now it fires every chase |

The ubergraph keeps its exact size, serialised **and at runtime**. Exactly 25
statements change - 19 four-byte cast operands and 6 constants - every other
statement sits at the same raw and runtime offset with the same text. 415 of
the 422 exports are untouched byte for byte.

### Do not "blank" bytecode in the middle of a function

This shipped once and corrupted the game. Cooked bytecode is stored in a
**shorter** form than the one the engine runs: an object or property reference
is a 4-byte `FPackageIndex` on disk and an 8-byte pointer in memory. Jump
targets, latent-action linkages and the ubergraph's entry points are all
*runtime* offsets, and `ScriptBytecodeSize` is a runtime length.

So "same number of bytes on disk" is **not** good enough. Filling 101 bytes
with `EX_Nothing` was byte-for-byte neutral on disk and still shortened the
runtime image by 64 bytes, because those 101 bytes expanded to 165 when
loaded. Every jump past that point then pointed into the middle of another
instruction.

`catbody-build.py` now disassembles every function it touches before and after
and refuses to write the file if any runtime length moves. Only two kinds of
edit are safe here: overwriting a fixed-width constant in place, or replacing
a whole function body and rewriting its `ScriptBytecodeSize` - which is what
`Jumpscared` does.

Known trade-off: skipping the first `Door_inward_C` block also drops Foxy's
`m_bIgnoreBlockChair = True`, so chairs block doors again like they do in the
stock game.

### When do broken doors come back?

They do not, until the level is actually reloaded. The break swaps the door's
`MeshDoor` and `Casing` for `box2`, spawns a `BP_DestructibleDoor_C` and never
touches them again - there is no restore path anywhere in the graph. Getting
caught does not reload the level, it only teleports the player back, so a door
smashed on one break-in is still gone on the next. Quitting to the menu and
loading the act again rebuilds it.

## Cat_In_The_Hat_STOCK.zip

The Cat mod exactly as downloaded, repacked. Use this one.

## Cat_In_The_Hat.zip - DEAD END, do not use

An attempt to reparent `BP_Cat_hat_C` onto `AI_Foxy_Original_C`. Tested on
hardware: a cooked `BlueprintGeneratedClass` inherits its parent's *data* but
runs none of its *code*, so the Cat got Foxy's animations and sounds and none
of his behaviour. FoxyReignited itself demonstrates the same thing -
`AI_Foxy_Nightmare` is a full duplicate of `AI_Foxy_Original`, not a subclass.
Kept only so the mistake is not repeated.
