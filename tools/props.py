#!/usr/bin/env python3
"""Read UE4 tagged properties out of a cooked export (e.g. a CDO)."""
import struct, sys
sys.path.insert(0, '/tmp/mods')
from uasset import Asset, R


def read_props(a, data, off, end, depth=0):
    r = R(data, off)
    out = []
    while r.o < end - 8:
        try:
            pname = a.name(r.i64())
        except Exception:
            break
        if pname == 'None':
            break
        try:
            ptype = a.name(r.i64())
            size = r.i32()
            idx = r.i32()
        except Exception:
            break
        extra = ''
        boolval = None
        if ptype == 'StructProperty':
            extra = a.name(r.i64())
            r.raw(16)
        elif ptype == 'BoolProperty':
            boolval = r.u8()
        elif ptype in ('ByteProperty', 'EnumProperty'):
            extra = a.name(r.i64())
        elif ptype in ('ArrayProperty', 'SetProperty'):
            extra = a.name(r.i64())
        elif ptype == 'MapProperty':
            extra = a.name(r.i64()) + '->' + a.name(r.i64())
        if r.o >= len(data):
            break
        hasguid = r.u8()
        if hasguid:
            r.raw(16)
        vstart = r.o
        raw = data[vstart:vstart + size]
        val = None
        if ptype == 'BoolProperty':
            val = bool(boolval)
        elif ptype == 'FloatProperty' and size == 4:
            val = round(struct.unpack('<f', raw)[0], 4)
        elif ptype == 'IntProperty' and size == 4:
            val = struct.unpack('<i', raw)[0]
        elif ptype == 'ByteProperty' and size == 8:
            val = a.name(struct.unpack('<q', raw)[0])
        elif ptype == 'ObjectProperty' and size == 4:
            val = a.classname(struct.unpack('<i', raw)[0])
        elif ptype == 'NameProperty' and size == 8:
            val = a.name(struct.unpack('<q', raw)[0])
        elif ptype == 'StructProperty' and extra == 'Vector' and size == 12:
            val = tuple(round(x, 2) for x in struct.unpack('<3f', raw))
        out.append((pname, ptype, extra, size, val, vstart))
        r.o = vstart + size
    return out


if __name__ == '__main__':
    path, want = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else None)
    data = open(path, 'rb').read()
    a = Asset(data)
    for e in a.exports:
        if want and want not in e['name']:
            continue
        if e['size'] == 0:
            continue
        props = read_props(a, data, e['off'], e['off'] + e['size'])
        if not props:
            continue
        print(f"\n--- {e['name']}  ({a.classname(e['class'])}, {e['size']} B @ {e['off']}) ---")
        for (pn, pt, ex, sz, val, vo) in props:
            v = '' if val is None else f'= {val}'
            print(f"   {pn:<34} {pt:<16}{('['+ex+']') if ex else '':<22} {sz:>6} B @{vo:<8} {v}")
