#!/usr/bin/env python3
"""
foxy-tune.py - retune the FoxyReignited neighbour to the spec we agreed.

What it changes, and nothing else:

  bInstallCameras     off -> ON
  bInstallBuckets     off -> ON
  bThrowGlue          off -> ON
  bUseVacuumCleaner   off -> ON
  bThrowTomato        off -> stays OFF
  m_fStealUp        175.0 -> 600.0
  m_fWalk           291.7 -> 600.0
  m_fRun           3500.0 -> 5500.0

Bear traps are already on: the mod never writes that flag, so it inherits the
base game's default, which is enabled.

Every edit is the same number of bytes as what it replaces, so the file never
changes length and the pak never has to be rebuilt. Properties are located by
NAME, parsed out of the asset - no hardcoded offsets - and the script refuses
to write anything if what it finds does not look exactly as expected.

Usage:
  tools/foxy-tune.py <FoxyReignited.pak> [--dry-run]

A .bak of the pak is kept the first time it runs.
"""

import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

try:
    from uasset import Asset
except ImportError:
    sys.exit('error: uasset.py must sit next to this script (tools/)')

ASSET = 'AI_Foxy_Original.uasset'

BOOLS_ON = ('bInstallCameras', 'bInstallBuckets', 'bThrowGlue', 'bUseVacuumCleaner')
BOOLS_OFF = ('bThrowTomato',)
FLOATS = {'m_fStealUp': 600.0, 'm_fWalk': 600.0, 'm_fRun': 5500.0}

# tagged property: name(8) type(8) size(4) arrayIndex(4) [typedata] [guidflag(1)] value
TAG_FIXED = 24


def find_tags(asset, data, want):
    """Locate tagged properties by name anywhere in the file.

    Returns {name: (tag_offset, type_name)}. A tag is two FNames back to back,
    so we look for the name index followed by number 0, then check that the
    next FName resolves to something ending in 'Property'.
    """
    try:
        idx = {asset.names[i]: i for i in range(len(asset.names))}
    except Exception:
        sys.exit('error: could not read the asset name table')
    found = {}
    for nm in want:
        if nm not in idx:
            continue
        needle = struct.pack('<ii', idx[nm], 0)
        pos = 0
        while True:
            pos = data.find(needle, pos)
            if pos < 0:
                break
            try:
                tni = struct.unpack_from('<i', data, pos + 8)[0]
                tnn = struct.unpack_from('<i', data, pos + 12)[0]
                tname = asset.names[tni] if 0 <= tni < len(asset.names) else ''
            except Exception:
                tname = ''
            if tnn == 0 and tname.endswith('Property'):
                found[nm] = (pos, tname)
                break
            pos += 1
    return found


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    dry = '--dry-run' in sys.argv[1:]
    if len(args) != 1:
        sys.stderr.write(__doc__)
        raise SystemExit(2)
    pak_path = args[0]
    if not os.path.isfile(pak_path):
        sys.exit('error: no such file: %s' % pak_path)

    sys.path.insert(0, HERE)
    import importlib.util
    spec = importlib.util.spec_from_file_location('pp', os.path.join(HERE, 'patch-pak.py'))
    pp = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pp)

    pak = pp.load(pak_path)
    hits = [e for e in pak['entries'] if e['name'].endswith(ASSET)]
    if not hits:
        sys.exit('error: %s is not in this pak. Is this the FoxyReignited pak?' % ASSET)
    e = hits[0]
    with open(pak_path, 'rb') as f:
        f.seek(e['offset'])
        hr = pp.Reader(f.read(256))
        pp.read_entry(hr, pak['version'])
        f.seek(e['offset'] + hr.o)
        data = bytearray(f.read(e['size']))

    asset = Asset(bytes(data))
    want = list(BOOLS_ON) + list(BOOLS_OFF) + list(FLOATS)
    tags = find_tags(asset, bytes(data), want)

    missing = [n for n in want if n not in tags]
    if missing:
        sys.exit('error: could not find these properties: %s\n'
                 'This does not look like the FoxyReignited build this script was '
                 'written for; refusing to write.' % ', '.join(missing))

    plan = []
    for nm in list(BOOLS_ON) + list(BOOLS_OFF):
        off, ty = tags[nm]
        if ty != 'BoolProperty':
            sys.exit('error: %s is a %s, expected BoolProperty' % (nm, ty))
        at = off + TAG_FIXED                         # bool value lives in the tag
        cur = data[at]
        if cur not in (0, 1):
            sys.exit('error: %s at %d reads %#04x, not a clean 0/1 - refusing to write'
                     % (nm, at, cur))
        new = 1 if nm in BOOLS_ON else 0
        plan.append((nm, at, 1, '%s' % ('ON' if cur else 'off'),
                     '%s' % ('ON' if new else 'off'), bytes([new])))

    for nm, newval in FLOATS.items():
        off, ty = tags[nm]
        if ty != 'FloatProperty':
            sys.exit('error: %s is a %s, expected FloatProperty' % (nm, ty))
        at = off + TAG_FIXED + 1                     # skip the has-guid byte
        cur = struct.unpack_from('<f', data, at)[0]
        if not (0.0 < cur < 100000.0):
            sys.exit('error: %s at %d reads %r - that is not a sane speed, refusing'
                     % (nm, at, cur))
        plan.append((nm, at, 4, '%g' % cur, '%g' % newval, struct.pack('<f', newval)))

    print('pak   : %s' % os.path.basename(pak_path))
    print('asset : %s (%d bytes)\n' % (ASSET, len(data)))
    print('  %-20s %-10s %-10s %s' % ('property', 'now', 'becomes', 'at'))
    print('  ' + '-' * 52)
    for nm, at, n, cur, new, raw in plan:
        mark = ' ' if cur == new else '*'
        print('%s %-20s %-10s %-10s %d' % (mark, nm, cur, new, at))

    changed = sum(1 for p in plan if p[3] != p[4])
    print('\n%d of %d properties need changing.' % (changed, len(plan)))
    if dry:
        print('--dry-run: nothing written')
        return
    if not changed:
        print('Already tuned; nothing to do.')
        return

    for nm, at, n, cur, new, raw in plan:
        data[at:at + n] = raw

    before = e['size']
    if len(data) != before:
        sys.exit('internal error: asset changed size %d -> %d' % (before, len(data)))

    tmp = tempfile.NamedTemporaryFile(delete=False, suffix='.uasset')
    tmp.write(bytes(data))
    tmp.close()
    try:
        print()
        rc = subprocess.call([sys.executable, os.path.join(HERE, 'patch-pak.py'),
                              pak_path, ASSET, tmp.name])
    finally:
        os.unlink(tmp.name)
    if rc != 0:
        sys.exit('error: patch-pak.py failed (%d)' % rc)
    print('\nDone. Launch the game and pick the Foxy mod.')


if __name__ == '__main__':
    main()
