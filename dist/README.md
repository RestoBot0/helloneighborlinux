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
| `Animations`, `Sounds`, `Head` tags renamed to `HNX_Removed` | makes UE4 skip the tag so the value falls back to `BP_Sosed`'s; Foxy's animations are built for `Ignited_Foxy_Skeleton` and cannot play on the Cat |
| `SoundStruck` -> Cat `secretsound_Cue` | matches what `BP_Cat_hat` does |
| `attack_sound.Sound` -> Cat `panic_Cue` | the chase music; same component the Cat mod uses for it |
| `Audio.Sound` -> `Cat_Whistling_Bored_Talking_Cue` | replaces Foxy's `IdleNoises_Cue`, the mechanical whirring |
| `ClassBearTrap` tag removed | falls back to the stock `BP_Trap_C` instead of `BP_FoxyTrap_C` |
| `Jumpscared()` body replaced with a bare return | that event was `Delay(1s)` then `Create(WG_SdaltSpam_C)` + `AddToViewport`. The "HEY" shout is a different event (`IntroWidgets` -> `WG_FshoutFR_C`) and is left alone |
| speeds 600 / 600 / 5500, traps all on except tomato | the requested spec |

The ubergraph bytecode is byte-identical to the original, and 417 of the 422
exports are untouched byte for byte.

## Cat_In_The_Hat_STOCK.zip

The Cat mod exactly as downloaded, repacked. Use this one.

## Cat_In_The_Hat.zip - DEAD END, do not use

An attempt to reparent `BP_Cat_hat_C` onto `AI_Foxy_Original_C`. Tested on
hardware: a cooked `BlueprintGeneratedClass` inherits its parent's *data* but
runs none of its *code*, so the Cat got Foxy's animations and sounds and none
of his behaviour. FoxyReignited itself demonstrates the same thing -
`AI_Foxy_Nightmare` is a full duplicate of `AI_Foxy_Original`, not a subclass.
Kept only so the mistake is not repeated.
