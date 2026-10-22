#!/usr/bin/env python3
"""Minimal cooked UE4 .uasset header parser: name table, imports, exports."""
import struct, sys

TAG = 0x9E2A83C1


class R:
    def __init__(self, b, o=0):
        self.b = b; self.o = o

    def i32(self):
        v = struct.unpack_from('<i', self.b, self.o)[0]; self.o += 4; return v

    def u32(self):
        v = struct.unpack_from('<I', self.b, self.o)[0]; self.o += 4; return v

    def i64(self):
        v = struct.unpack_from('<q', self.b, self.o)[0]; self.o += 8; return v

    def u16(self):
        v = struct.unpack_from('<H', self.b, self.o)[0]; self.o += 2; return v

    def raw(self, n):
        v = self.b[self.o:self.o + n]; self.o += n; return v

    def fstring(self):
        n = self.i32()
        if n == 0:
            return ''
        if n < 0:
            return self.raw(-n * 2).decode('utf-16-le', 'replace').rstrip('\0')
        return self.raw(n).decode('utf-8', 'replace').rstrip('\0')


class Asset:
    def __init__(self, data):
        self.data = data
        r = R(data)
        tag = r.u32()
        if tag != TAG:
            raise ValueError('not a uasset (tag=%08x)' % tag)
        self.legacy = r.i32()
        if self.legacy != -4:
            r.i32()                                  # LegacyUE3Version
        self.ue4ver = r.i32()
        self.licensee = r.i32()
        self.unversioned = (self.ue4ver == 0 and self.licensee == 0)
        if self.unversioned:
            self.ue4ver = 514          # cooked unversioned -> engine ver (UE 4.20)
        if self.legacy <= -2:
            n = r.i32()                              # custom versions
            r.raw(n * 20)
        self.header_size = r.i32()
        self.folder = r.fstring()
        self.flags = r.u32()
        self.name_count = r.i32()
        self.name_offset = r.i32()
        if self.ue4ver >= 459:                       # gatherable text
            r.i32(); r.i32()
        self.export_count = r.i32()
        self.export_offset = r.i32()
        self.import_count = r.i32()
        self.import_offset = r.i32()

        # --- names ---
        self.names = []
        nr = R(data, self.name_offset)
        for _ in range(self.name_count):
            s = nr.fstring()
            if self.ue4ver >= 504:
                nr.u16(); nr.u16()                   # hashes
            self.names.append(s)

        # --- imports ---
        self.imports = []
        ir = R(data, self.import_offset)
        for _ in range(self.import_count):
            cp = self.name(ir.i64()); cn = self.name(ir.i64())
            outer = ir.i32(); obj = self.name(ir.i64())
            self.imports.append((cp, cn, outer, obj))

        # --- exports ---
        self.exports = []
        er = R(data, self.export_offset)
        for _ in range(self.export_count):
            cls = er.i32(); sup = er.i32()
            if self.ue4ver >= 508: er.i32()          # template index
            outer = er.i32()
            obj = self.name(er.i64())
            er.u32()                                  # object flags
            if self.ue4ver >= 511:
                ssize = er.i64(); soff = er.i64()
            else:
                ssize = er.i32(); soff = er.i32()
            er.i32(); er.i32(); er.i32()              # forced/notclient/notserver
            er.raw(16); er.u32()                      # guid + package flags
            if self.ue4ver >= 365: er.i32()
            if self.ue4ver >= 485: er.i32()
            if self.ue4ver >= 507:
                for _ in range(5): er.i32()
            self.exports.append({'class': cls, 'super': sup, 'outer': outer,
                                 'name': obj, 'size': ssize, 'off': soff})

    def classname(self, idx):
        """Resolve an FPackageIndex to a readable class name."""
        if idx < 0:
            i = -idx - 1
            return self.imports[i][3] if i < len(self.imports) else '?'
        if idx > 0:
            i = idx - 1
            return self.exports[i]['name'] if i < len(self.exports) else '?'
        return 'None'

    def name(self, idx):
        """FName is int32 index + int32 number, packed here as int64."""
        i = idx & 0xFFFFFFFF
        num = (idx >> 32) & 0xFFFFFFFF
        s = self.names[i] if i < len(self.names) else '<bad:%d>' % i
        return s + ('_%d' % (num - 1) if num else '')


if __name__ == '__main__':
    a = Asset(open(sys.argv[1], 'rb').read())
    print(f'ue4ver={a.ue4ver} names={a.name_count} imports={a.import_count} exports={a.export_count}')
    what = sys.argv[2] if len(sys.argv) > 2 else 'names'
    if what == 'names':
        for i, n in enumerate(a.names):
            print(f'{i:>5}  {n}')
    elif what == 'exports':
        for e in a.exports:
            print(f"  {a.classname(e['class']):<26} {e['name']:<44} {e['size']:>9,} B")
    elif what == 'imports':
        for cp, cn, o, ob in a.imports:
            print(f'  {cn:<28} {ob}   (pkg {cp})')
