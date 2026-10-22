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
    kill_tag(prop(cdo, 'Animations'), '(Foxy anims are on the wrong skeleton)')
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

    # ---- audio components ----------------------------------------------
    for comp, idx, what in (
        ('attack_sound_GEN_VARIABLE', panic, 'Cat panic_Cue (chase music)'),
        ('Audio_GEN_VARIABLE', whistle, 'Cat_Whistling_Bored_Talking_Cue (idle)'),
    ):
        e = find_export(a, comp)
        ps = walk(a, data, e['off'], e['off'] + e['size'])
        log.append(comp)
        set_ref(prop(ps, 'Sound'), idx, what)

    # ---- blank the jumpscare -------------------------------------------
    e = find_export(a, 'Jumpscared')
    blob = data[e['off']:e['off'] + e['size']]
    # A UFunction export ends with int32 ScriptBytecodeSize (runtime size),
    # int32 ScriptStorageSize (serialised size), then the bytecode. Both the
    # bsz >= ssz test and the EX_EndOfScript terminator are needed: without
    # the first, the scan happily matches four bytes earlier and corrupts
    # ScriptStorageSize.
    hdr = None
    for h in range(12, len(blob) - 4):
        bsz = struct.unpack_from('<i', blob, h - 8)[0]
        ssz = struct.unpack_from('<i', blob, h - 4)[0]
        if 0 < ssz <= len(blob) - h and bsz >= ssz and blob[h + ssz - 1] == 0x53:
            hdr, size = h, ssz
            break
    if hdr is None:
        raise SystemExit('Jumpscared: could not find the bytecode')
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
