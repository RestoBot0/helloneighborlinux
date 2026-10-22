#!/usr/bin/env python3
"""
catbody-build.py - build the Cat-bodied Neighbour from FoxyReignited's AI class.

Why this shape
--------------
Reparenting the Cat's Blueprint onto Foxy's class was tested on hardware and
failed: a cooked BlueprintGeneratedClass inherits its parent's *data* but none
of its *code*. (FoxyReignited itself proves the point - AI_Foxy_Nightmare is a
full byte-for-byte duplicate of AI_Foxy_Original, not a subclass.)

So we go the other way round: keep AI_Foxy_Original_C, the class that already
works, and give it the Cat's body and the Cat's audio.

What it changes, and why
------------------------
  CharacterMesh0.SkeletalMesh  -> Cat_in_the_hat_rig
        The Cat mesh is rigged to /Game/Sosed/Animations/neighbour_lowpoly_Skeleton
        (verified in Cat_in_the_hat_rig.uasset), i.e. the stock Neighbour
        skeleton, so it is a straight swap.

  CharacterMesh0.AnimClass     -> SosedAnimBlueprint_C
        NOT the Cat mod's CATAnimBlueprint. That blueprint has no AnimNode_Slot
        / DefaultSlot in its graph (Ignited_Foxy_AnimBP does), and an Animation
        Montage with no matching Slot node in the AnimGraph silently produces
        nothing. Every montage-driven action - opening doors, looking around,
        sitting, setting traps - therefore did nothing at all. The stock
        Neighbour blueprint targets the same skeleton and has the slot.

  Animations / Sounds / Head   -> tag renamed to HNX_Removed
        UE4 only serialises deltas from the parent CDO, and it skips a tagged
        property whose name does not resolve to a real UProperty. Renaming the
        tag therefore makes the value fall back to BP_Sosed's - the stock
        Neighbour animation set and voice - in a strictly size-neutral way.
        Foxy's own animations are built for Ignited_Foxy_Skeleton and cannot
        play on the Cat.

  SoundStruck                  -> Cat secretsound_Cue    (Cat, matches BP_Cat_hat)
  attack_sound.Sound           -> Cat panic_Cue          (the chase music)
  Audio.Sound                  -> Cat_Whistling_Bored_Talking_Cue (idle voice;
        replaces Foxy's IdleNoises_Cue, the mechanical whirring)

  Jumpscared()                 -> body replaced with "return"
        That event is a 1 second delay followed by Create(WG_SdaltSpam_C) +
        AddToViewport. Blanking the stub leaves the ubergraph untouched; the
        widget code simply becomes unreachable. The "HEY" shout is a different
        event (IntroWidgets -> WG_FshoutFR_C) and is deliberately left alone.

  speeds + traps               -> Cat speed, everything on except tomato

Everything is located by name, never by a hardcoded offset, so the script stays
correct if the input ever changes.

Usage:  catbody-build.py <stock AI_Foxy_Original.uasset> <out.uasset>
"""

import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from uasset import Asset, R                      # noqa: E402
from uasset_edit import Editor                   # noqa: E402

DEAD = 'HNX_Removed'      # a name that resolves to no UProperty

# plugin content root -> package path, for assets supplied by the Cat mod
CAT = '/Cat_In_The_Hat/Content'
SOSED = '/Game/Sosed'


# --------------------------------------------------------------- properties
def walk(a, data, off, end):
    """Tagged-property walker that also reports where each *tag* starts."""
    r = R(data, off)
    out = []
    while r.o < end - 8:
        tstart = r.o
        try:
            pname = a.name(r.i64())
        except Exception:
            break
        if pname == 'None':
            break
        try:
            ptype = a.name(r.i64())
            size = r.i32()
            r.i32()                                   # array index
        except Exception:
            break
        extra = ''
        boolval = None
        if ptype == 'StructProperty':
            extra = a.name(r.i64())
            r.raw(16)
        elif ptype == 'BoolProperty':
            boolval = r.u8()
        elif ptype in ('ByteProperty', 'EnumProperty', 'ArrayProperty', 'SetProperty'):
            extra = a.name(r.i64())
        elif ptype == 'MapProperty':
            extra = a.name(r.i64()) + '->' + a.name(r.i64())
        if r.o >= len(data):
            break
        if r.u8():
            r.raw(16)                                 # property guid
        vstart = r.o
        out.append(dict(name=pname, type=ptype, extra=extra, size=size,
                        vstart=vstart, tstart=tstart, bool=boolval))
        r.o = vstart + size
    return out


def find_script(blob):
    """Locate the bytecode inside a Function export: (offset, size).

    A UFunction export ends with int32 ScriptBytecodeSize (the runtime size),
    int32 ScriptStorageSize (the serialised size), then the bytecode. Both the
    bsz >= ssz test and the EX_EndOfScript terminator are needed - without the
    first, the scan happily matches four bytes early and would corrupt
    ScriptStorageSize.
    """
    best = None
    for h in range(12, len(blob) - 4):
        bsz = struct.unpack_from('<i', blob, h - 8)[0]
        ssz = struct.unpack_from('<i', blob, h - 4)[0]
        if 0 < ssz <= len(blob) - h and bsz >= ssz and blob[h + ssz - 1] == 0x53:
            if best is None or ssz > best[1]:
                best = (h, ssz)
    if best is None:
        raise SystemExit('could not find the bytecode in a Function export')
    return best


def find_export(a, name):
    for e in a.exports:
        if e['name'] == name:
            return e
    raise KeyError('no export named %r' % name)


def prop(props, name):
    for p in props:
        if p['name'] == name:
            return p
    raise KeyError('no property named %r' % name)


# -------------------------------------------------------------------- build
def build(src, dst):
    data = open(src, 'rb').read()
    a = Asset(data)
    ed = Editor(data)
    log = []

    def add_asset(pkg_path, class_name, obj_name):
        """Import <obj_name> of type <class_name> living in package <pkg_path>."""
        pkg = ed.add_import('/Script/CoreUObject', 'Package', 0, pkg_path)
        return ed.add_import('/Script/Engine', class_name, pkg, obj_name)

    cat_rig = add_asset(CAT + '/Cat_in_the_hat_rig', 'SkeletalMesh', 'Cat_in_the_hat_rig')
    sosed_abp = add_asset(SOSED + '/SosedAnimBlueprint', 'AnimBlueprintGeneratedClass',
                          'SosedAnimBlueprint_C')
    panic = add_asset(CAT + '/Sounds/panic_Cue', 'SoundCue', 'panic_Cue')
    whistle = add_asset(CAT + '/Sounds/Cat_Whistling_Bored_Talking_Cue', 'SoundCue',
                        'Cat_Whistling_Bored_Talking_Cue')
    secret = add_asset(CAT + '/Sounds/secretsound_Cue', 'SoundCue', 'secretsound_Cue')

    # The Cat's whole voice lives in AnimNotifies inside its animations, so the
    # only way to hear it is to put those animations into the Animations struct:
    #   cat_grabbed_2               -> ignited-bonnie-jumpscare-remake (the scream)
    #   cat_lookunder_bed_start     -> pieceofcake_Cue (the laugh)
    #   Cat_Anim_rig_LookAround     -> Cat_Whistling_Bored_Talking_Cue (idle)
    #   Cat_Anim_rig_fall_run       -> secretsound_Cue
    #   Cat_Anim_rig_spotted        -> sosed_voice_shouts_Cue
    cat_anim = {n: add_asset(CAT + '/anims/' + n, 'AnimSequence', n) for n in (
        'Cat_Anim_rig_fall_run', 'cat_grabbed_2', 'cat_lookunder_bed_start',
        'Cat_Anim_rig_LookAround', 'Cat_Anim_rig_spotted')}
    dead_idx = ed.add_name(DEAD)

    def kill_tag(p, why):
        """Rename a property tag so UE4 skips it and inherits the parent value."""
        ed.pending.append((p['tstart'], '<i', dead_idx))
        ed.pending.append((p['tstart'] + 4, '<i', 0))
        log.append('  inherit  %-16s %s' % (p['name'], why))

    def set_ref(p, idx, what):
        ed.write_object_ref(p['vstart'], idx)
        log.append('  point    %-16s -> %s' % (p['name'], what))

    def set_f32(p, v):
        ed.pending.append((p['vstart'], '<f', float(v)))
        log.append('  set      %-16s = %s' % (p['name'], v))

    def set_bool(p, v):
        # props.py reports the bool byte two bytes late; the real one is here
        ed.pending.append((p['tstart'] + 24, '<B', 1 if v else 0))
        log.append('  set      %-16s = %s' % (p['name'], bool(v)))

    # ---- the character mesh -------------------------------------------
    e = find_export(a, 'CharacterMesh0')
    mesh = walk(a, data, e['off'], e['off'] + e['size'])
    log.append('CharacterMesh0')
    set_ref(prop(mesh, 'SkeletalMesh'), cat_rig, 'Cat_in_the_hat_rig')
    set_ref(prop(mesh, 'AnimClass'), sosed_abp,
            'SosedAnimBlueprint_C  (has a DefaultSlot; CATAnimBlueprint does not)')

    # ---- the class default object --------------------------------------
    e = find_export(a, 'Default__AI_Foxy_Original_C')
    cdo = walk(a, data, e['off'], e['off'] + e['size'])
    log.append('Default__AI_Foxy_Original_C')
    kill_tag(prop(cdo, 'Sounds'), '(drops Foxy voicelines)')
    kill_tag(prop(cdo, 'Head'), '(head setup belongs to Foxy mesh)')
    set_ref(prop(cdo, 'SoundStruck'), secret, 'Cat secretsound_Cue')
    set_f32(prop(cdo, 'm_fStealUp'), 600)
    set_f32(prop(cdo, 'm_fWalk'), 600)
    set_f32(prop(cdo, 'm_fRun'), 5500)

    traps = prop(cdo, 'm_InstallTraps')
    inner = walk(a, data, traps['vstart'], traps['vstart'] + traps['size'])
    want = {'bInstallCameras': True, 'bInstallBuckets': True, 'bThrowGlue': True,
            'bThrowTomato': False, 'bUseVacuumCleaner': True}
    log.append('m_InstallTraps')
    seen = set()
    for p in inner:
        if p['name'] in want:
            set_bool(p, want[p['name']])
            seen.add(p['name'])
    missing = set(want) - seen
    if missing:
        raise SystemExit('m_InstallTraps: could not locate %s' % sorted(missing))
    # Foxy swaps the bear trap for his own BP_FoxyTrap_C; fall back to the
    # stock BP_Trap_C that BP_Sosed names.
    kill_tag(prop(inner, 'ClassBearTrap'), '(use the stock bear trap)')

    # ---- the Animations struct -----------------------------------------
    # Foxy fills 21 of the 30 slots with animations built for
    # Ignited_Foxy_Skeleton, which cannot play on the Cat. Drop the tag on each
    # one so it falls back to BP_Sosed's stock Neighbour animation, except the
    # handful where the Cat mod ships a real animation of its own - those carry
    # the Cat's voice as AnimNotifies.
    anims = prop(cdo, 'Animations')
    inner = walk(a, data, anims['vstart'], anims['vstart'] + anims['size'])
    use = {
        'BaseBlueprintClass': (sosed_abp, 'SosedAnimBlueprint_C'),
        'Fall': (cat_anim['Cat_Anim_rig_fall_run'], 'Cat_Anim_rig_fall_run'),
        'SlipAndFall': (cat_anim['Cat_Anim_rig_fall_run'], 'Cat_Anim_rig_fall_run'),
        'Catch': (cat_anim['cat_grabbed_2'], 'cat_grabbed_2  (the scream)'),
        'BedLookStart': (cat_anim['cat_lookunder_bed_start'],
                         'cat_lookunder_bed_start  (the laugh)'),
        'LookAround': (cat_anim['Cat_Anim_rig_LookAround'],
                       'Cat_Anim_rig_LookAround  (the idle whistle)'),
        'Afraid': (cat_anim['Cat_Anim_rig_spotted'], 'Cat_Anim_rig_spotted'),
    }
    log.append('Animations')
    for p in inner:
        if p['name'] in use:
            idx, what = use[p['name']]
            set_ref(p, idx, what)
        else:
            kill_tag(p, '(stock Neighbour animation)')
    unseen = set(use) - {p['name'] for p in inner}
    if unseen:
        raise SystemExit('Animations: missing fields %s' % sorted(unseen))

    # ---- audio components ----------------------------------------------
    for comp, idx, what in (
        ('attack_sound_GEN_VARIABLE', panic, 'Cat panic_Cue (chase music)'),
        ('Audio_GEN_VARIABLE', whistle, 'Cat_Whistling_Bored_Talking_Cue (idle)'),
    ):
        e = find_export(a, comp)
        ps = walk(a, data, e['off'], e['off'] + e['size'])
        log.append(comp)
        set_ref(prop(ps, 'Sound'), idx, what)

    # ---- stop BeginPlay installing Foxy animations on the world ---------
    # ReceiveBeginPlay sweeps the level and overwrites the animation that every
    # sofa, bath, sink, bed, ladder, TV, chair, cupboard, door and bear trap
    # asks the Neighbour to play, pointing them all at Foxy animations. On the
    # Cat those are the wrong skeleton, so the Neighbour plays nothing at all -
    # which is exactly the "a lot of his animations are gone" report.
    #
    # Each of those blocks sits behind "cast the actor to BP_X_C" followed by
    # PopExecutionFlowIfNot. Repointing the cast's class operand at a class no
    # actor can ever be makes the cast fail, and the block is skipped down the
    # same path the game already takes for every actor that is not a BP_X_C.
    # The operand is a 4-byte FPackageIndex, so this is size-neutral in both
    # the serialised stream and the runtime bytecode - no jump offset moves.
    EX_DYNAMIC_CAST = 0x2E
    uber = find_export(a, 'ExecuteUbergraph_AI_Foxy_Original')
    ublob = data[uber['off']:uber['off'] + uber['size']]
    uhdr, usize = find_script(ublob)
    code = ublob[uhdr:uhdr + usize]

    def import_index(name):
        hits = [-(i + 1) for i, imp in enumerate(a.imports) if imp[3] == name]
        if len(hits) != 1:
            raise SystemExit('import %r found %d times' % (name, len(hits)))
        return hits[0]

    dead_class = import_index('WG_SdaltSpam_C')      # a widget; never an actor
    #            class name                 how many casts, how many to kill
    BLOCKS = [('BP_Sofa_C', 1, 1), ('BP_Bath_C', 1, 1), ('BP_Bath2_C', 2, 2),
              ('BP_Kithen_sink_C', 1, 1), ('BP_Kitchen_sink_C', 1, 1),
              ('BP_Armchair_C', 1, 1), ('BP_Chair_C', 1, 1),
              ('BP_Window_1_C', 1, 1), ('BP_Window_3_C', 1, 1),
              ('BP_Toilet_C', 1, 1), ('BP_Bed_C', 1, 1), ('BP_TwinBed_C', 1, 1),
              ('BP_Cupboard_C', 1, 1), ('BP_Trap_C', 1, 1), ('BP_Ladder_C', 1, 1),
              ('BP_TV_C', 1, 1), ('BP_DoorTimesDay_C', 1, 1),
              ('BP_Human_C', 2, 2),
              # two casts: the first is the BeginPlay animation override, the
              # second drives the door break. Only ever kill the first.
              ('Door_inward_C', 2, 1)]
    log.append('ReceiveBeginPlay: skip the Foxy animation overrides')
    killed = 0
    for cls, expect, kill in BLOCKS:
        idx = import_index(cls)
        pat = bytes([EX_DYNAMIC_CAST]) + struct.pack('<i', idx)
        at, found = 0, []
        while True:
            at = code.find(pat, at)
            if at < 0:
                break
            found.append(at)
            at += 1
        if len(found) != expect:
            raise SystemExit('%s: expected %d casts, found %d' % (cls, expect, len(found)))
        for o in found[:kill]:
            ed.pending.append((uber['off'] + uhdr + o + 1, '<i', dead_class))
            killed += 1
        log.append('  skip     %-22s cast at +%d%s' %
                   (cls, found[0], '' if kill == expect else '  (kept %d)' % (expect - kill)))
    if killed != 21:
        raise SystemExit('expected to neutralise 21 casts, did %d' % killed)

    # ---- blank the jumpscare -------------------------------------------
    e = find_export(a, 'Jumpscared')
    blob = data[e['off']:e['off'] + e['size']]
    hdr, size = find_script(blob)
    if blob[hdr] != 0x1B:                 # EX_FinalFunction - the stub shape
        raise SystemExit('Jumpscared: unexpected bytecode, refusing to patch')
    # EX_Return EX_Nothing, padded with EX_Nothing, terminated by EX_EndOfScript
    body = bytes([0x04, 0x0B]) + bytes([0x0B]) * (size - 3) + bytes([0x53])
    assert len(body) == size
    ed.pending.append((e['off'] + hdr, '<%ds' % size, body))
    ed.pending.append((e['off'] + hdr - 8, '<i', size))      # runtime size
    log.append('Jumpscared')
    log.append('  blank    %-16s (was: delay 1s -> WG_SdaltSpam full screen)' % 'body')

    out = ed.save()
    open(dst, 'wb').write(out)
    print('\n'.join(log))
    print('\n%s -> %s   %d -> %d bytes (%+d)' %
          (os.path.basename(src), os.path.basename(dst), len(data), len(out),
           len(out) - len(data)))
    return out


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit(__doc__.strip().splitlines()[-1])
    build(sys.argv[1], sys.argv[2])
