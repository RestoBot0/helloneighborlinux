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
| 21 `EX_DynamicCast` operands in `ReceiveBeginPlay` | BeginPlay swept the level and overwrote the animation every sofa, bath, sink, bed, ladder, TV, chair, cupboard, door and bear trap asks the Neighbour to play, pointing them all at Foxy animations. Each block sits behind a cast + `PopExecutionFlowIfNot`, so repointing the cast's class at `WG_SdaltSpam_C` (a widget - no actor can ever be one) makes the cast fail and the block is skipped down the path the game already takes for every non-matching actor. The operand is a 4-byte `FPackageIndex`, identical in size serialised and at runtime, so no jump offset moves. The second `Door_inward_C` cast - the door break - is deliberately left alone |
| `SoundStruck` -> Cat `secretsound_Cue` | matches what `BP_Cat_hat` does |
| `attack_sound.Sound` -> Cat `panic_Cue` | the chase music; same component the Cat mod uses for it |
| `Audio.Sound` -> `Cat_Whistling_Bored_Talking_Cue` | replaces Foxy's `IdleNoises_Cue`, the mechanical whirring |
| `ClassBearTrap` tag removed | falls back to the stock `BP_Trap_C` instead of `BP_FoxyTrap_C` |
| `Jumpscared()` body replaced with a bare return | that event was `Delay(1s)` then `Create(WG_SdaltSpam_C)` + `AddToViewport`. The "HEY" shout is a different event (`IntroWidgets` -> `WG_FshoutFR_C`) and is left alone |
| speeds 600 / 600 / 5500, traps all on except tomato | the requested spec |

The ubergraph keeps its exact size and structure - 42 bytes change, all of them
inside those 21 cast operands - and it re-disassembles to the same 3,592 nodes
with zero errors. 416 of the 422 exports are untouched byte for byte.

Known trade-off: skipping the first `Door_inward_C` block also drops Foxy's
`m_bIgnoreBlockChair = True`, so chairs block doors again like they do in the
stock game. He still smashes the door while hunting.

## Cat_In_The_Hat_STOCK.zip

The Cat mod exactly as downloaded, repacked. Use this one.

## Cat_In_The_Hat.zip - DEAD END, do not use

An attempt to reparent `BP_Cat_hat_C` onto `AI_Foxy_Original_C`. Tested on
hardware: a cooked `BlueprintGeneratedClass` inherits its parent's *data* but
runs none of its *code*, so the Cat got Foxy's animations and sounds and none
of his behaviour. FoxyReignited itself demonstrates the same thing -
`AI_Foxy_Nightmare` is a full duplicate of `AI_Foxy_Original`, not a subclass.
Kept only so the mistake is not repeated.
