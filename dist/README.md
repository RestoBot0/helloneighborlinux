# Cat_In_The_Hat (door-breaking edition)

The Cat in the Hat with Foxy's door-breaking grafted on, while keeping his own
model, animations, jump and speed.

## How it works

`BP_Cat_hat` has no code of its own at all - it is a costume with a parent.
Its parent was `BP_Sosed_C`, the stock Neighbour. This build repoints that
parent at `AI_Foxy_Original_C`, so the Cat inherits Foxy's entire Blueprint
class, including the trigger box and the ubergraph that swaps a door for a
pre-fractured one and plays `Door_Break_Cue`.

Everything the Cat overrides in his own defaults still wins: his skeletal
mesh, his anim Blueprint, `m_fRun 5500`, `JumpMaxCount 3`, tomato off.

Three import records changed, three names added. No Foxy content is copied in.

## Install

Both folders go in `<game>/HelloNeighbor/Mods/`:

    Mods/Cat_In_The_Hat/      <- from this zip
    Mods/FoxyReignited/       <- the unmodified mod from ModDB

FoxyReignited must be present because the Cat now inherits from a class that
lives inside it. You do not select it - you select **Cat_In_The_Hat** in the
Modding menu. Its pak still gets mounted, which is what makes the parent
class resolvable.

## Credits

Cat in the Hat by Endersteve8479. Foxy Reignited by Sdalt. This is a personal
edit of both; please keep them credited.
