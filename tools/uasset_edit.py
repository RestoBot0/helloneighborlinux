#!/usr/bin/env python3
"""
uasset_edit.py - rewrite a cooked UE 4.20 .uasset: add names, repoint imports.

Reading a cooked asset is easy. Changing one is not, because the header is a
pile of absolute file offsets and every export records where its data starts.
Insert a single byte into the name table and all of it goes stale.

This module parses the full FPackageFileSummary while remembering *where* each
offset field lives, so that after growing the name table it can walk back and
add the delta to every one of them, plus every export's SerialOffset.

The two per-name hashes UE4 stores are reproduced exactly (verified against
all 112 names of BP_Cat_hat):

  NonCasePreservingHash = FCrc::Strihash_DEPRECATED - forward CRC table
                          (poly 0x04C11DB7, MSB-first), uppercased, 1 byte/char
  CasePreservingHash    = FCrc::StrCrc32 - reflected table (0xEDB88320),
                          4 bytes per character

Getting those wrong is not cosmetic: FName::FName(FNameEntrySerialized) seeds
the global name hash table with them, so a bad hash means later lookups by
string land in a different bucket and silently fail to match.
"""

import struct
import sys

TAG = 0x9E2A83C1


def _tbl_reflected():
    t = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (c >> 1) ^ (0xEDB88320 & -(c & 1))
        t.append(c)
    return t


def _tbl_forward():
    t = []
    for i in range(256):
        c = i << 24
        for _ in range(8):
            c = ((c << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if c & 0x80000000 else (c << 1) & 0xFFFFFFFF
        t.append(c)
    return t


_REFL = _tbl_reflected()
_FWD = _tbl_forward()


def strihash(s):
    """FCrc::Strihash_DEPRECATED, truncated to 16 bits."""
    h = 0
    for ch in s.upper():
        h = ((h >> 8) & 0x00FFFFFF) ^ _FWD[(h ^ (ord(ch) & 0xFF)) & 0xFF]
    return h & 0xFFFF


def strcrc32(s):
    """FCrc::StrCrc32, truncated to 16 bits."""
    crc = 0xFFFFFFFF
    for ch in s:
        v = ord(ch)
        for k in range(4):
            crc = (crc >> 8) ^ _REFL[(crc ^ ((v >> (8 * k)) & 0xFF)) & 0xFF]
    return (~crc) & 0xFFFF


class Cursor:
    def __init__(self, b, o=0):
        self.b = b
        self.o = o

    def i32(self):
        v = struct.unpack_from('<i', self.b, self.o)[0]
        self.o += 4
        return v

    def u32(self):
        v = struct.unpack_from('<I', self.b, self.o)[0]
        self.o += 4
        return v

    def i64(self):
        v = struct.unpack_from('<q', self.b, self.o)[0]
        self.o += 8
        return v

    def raw(self, n):
        v = self.b[self.o:self.o + n]
        self.o += n
        return v

    def fstring(self):
        n = self.i32()
        if n == 0:
            return ''
        if n < 0:
            s = self.raw(-n * 2)[:-2].decode('utf-16-le')
        else:
            s = self.raw(n)[:-1].decode('utf-8', 'replace')
        return s


class Editor:
    """Load an asset, mutate names/imports, write it back with offsets fixed."""

    def __init__(self, data):
        self.data = bytearray(data)
        self.i32_fields = {}        # label -> file position of an int32 offset
        self.i64_fields = {}
        self._parse()

    # ---------------------------------------------------------------- parse
    def _mark32(self, c, label):
        self.i32_fields[label] = c.o
        return c.i32()

    def _mark64(self, c, label):
        self.i64_fields[label] = c.o
        return c.i64()

    def _parse(self):
        d = self.data
        c = Cursor(d)
        if c.u32() != TAG:
            raise ValueError('not a .uasset')
        self.legacy = c.i32()
        if self.legacy != -4:
            c.i32()
        ue4 = c.i32()
        lic = c.i32()
        self.unversioned = (ue4 == 0 and lic == 0)
        self.ue4ver = 514 if self.unversioned else ue4
        if self.legacy <= -2:
            c.raw(c.i32() * 20)
        self.header_size = self._mark32(c, 'TotalHeaderSize')
        self.folder = c.fstring()
        c.u32()                                              # PackageFlags
        self.name_count_at = c.o
        self.name_count = c.i32()
        self.name_offset = c.i32()                           # start never moves
        if self.ue4ver >= 459:
            c.i32()
            self._mark32(c, 'GatherableTextDataOffset')
        self.export_count = c.i32()
        self.export_offset = self._mark32(c, 'ExportOffset')
        self.import_count = c.i32()
        self.import_offset = self._mark32(c, 'ImportOffset')
        self._mark32(c, 'DependsOffset')
        if self.ue4ver >= 384:
            c.i32()
            self._mark32(c, 'SoftPackageReferencesOffset')
        if self.ue4ver >= 510:
            self._mark32(c, 'SearchableNamesOffset')
        self._mark32(c, 'ThumbnailTableOffset')
        c.raw(16)                                            # package guid
        for _ in range(c.i32()):                             # generations
            c.i32(); c.i32()
        if self.ue4ver >= 336:
            c.raw(10); c.fstring()                           # SavedByEngineVersion
        if self.ue4ver >= 444:
            c.raw(10); c.fstring()                           # CompatibleWith
        c.u32()                                              # CompressionFlags
        if c.i32() != 0:
            raise ValueError('package has compressed chunks; unsupported')
        c.u32()                                              # PackageSource
        for _ in range(c.i32()):                             # AdditionalPackagesToCook
            c.fstring()
        if self.legacy > -7:
            c.i32()                                          # NumTextureAllocations
        self._mark32(c, 'AssetRegistryDataOffset')
        self._mark64(c, 'BulkDataStartOffset')
        if self.ue4ver >= 224:
            self._mark32(c, 'WorldTileInfoDataOffset')
        if self.ue4ver >= 326:
            for _ in range(c.i32()):
                c.i32()                                      # ChunkIDs
        if self.ue4ver >= 507:
            c.i32()
            self._mark32(c, 'PreloadDependencyOffset')
        self.summary_end = c.o

        # --- name table ---
        self.names = []
        self.name_table_end = None
        nc = Cursor(d, self.name_offset)
        for _ in range(self.name_count):
            self.names.append(nc.fstring())
            if self.ue4ver >= 504:
                nc.raw(4)
        self.name_table_end = nc.o

        # --- imports: remember where each FName field sits ---
        self.imports = []
        ic = Cursor(d, self.import_offset)
        for _ in range(self.import_count):
            rec = {'at': ic.o}
            rec['classpackage_at'] = ic.o; cp = ic.i64()
            rec['classname_at'] = ic.o;    cn = ic.i64()
            rec['outer_at'] = ic.o;        rec['outer'] = ic.i32()
            rec['objectname_at'] = ic.o;   ob = ic.i64()
            rec['classpackage'] = self.nm(cp)
            rec['classname'] = self.nm(cn)
            rec['objectname'] = self.nm(ob)
            self.imports.append(rec)

        # --- exports: remember where each SerialOffset sits ---
        self.exports = []
        ec = Cursor(d, self.export_offset)
        for _ in range(self.export_count):
            rec = {'at': ec.o}
            rec['class_at'] = ec.o; rec['class'] = ec.i32()
            rec['super_at'] = ec.o; rec['super'] = ec.i32()
            if self.ue4ver >= 508:
                rec['template_at'] = ec.o; rec['template'] = ec.i32()
            rec['outer_at'] = ec.o; rec['outer'] = ec.i32()
            rec['name'] = self.nm(ec.i64())
            ec.u32()
            if self.ue4ver >= 511:
                rec['size'] = ec.i64()
                rec['off_at'] = ec.o
                rec['off'] = ec.i64()
            else:
                rec['size'] = ec.i32()
                rec['off_at'] = ec.o
                rec['off'] = ec.i32()
            ec.i32(); ec.i32(); ec.i32()
            ec.raw(16); ec.u32()
            if self.ue4ver >= 365: ec.i32()
            if self.ue4ver >= 485: ec.i32()
            if self.ue4ver >= 507:
                for _ in range(5): ec.i32()
            self.exports.append(rec)

    # ----------------------------------------------------------- accessors
    def nm(self, packed):
        i = packed & 0xFFFFFFFF
        num = (packed >> 32) & 0xFFFFFFFF
        s = self.names[i] if i < len(self.names) else '<bad:%d>' % i
        return s + ('_%d' % (num - 1) if num else '')

    def name_index(self, s):
        try:
            return self.names.index(s)
        except ValueError:
            return None

    # ------------------------------------------------------------ mutation
    def add_name(self, s):
        """Append a name, returning its index. Existing names are reused."""
        i = self.name_index(s)
        if i is not None:
            return i
        self.names.append(s)
        return len(self.names) - 1

    def set_import_field(self, imp_index, field, name):
        """Point one FName field of an import at `name` (added if needed)."""
        rec = self.imports[imp_index]
        key = field + '_at'
        if key not in rec:
            raise KeyError('no such import field: %s' % field)
        idx = self.add_name(name)
        rec['_writes'] = rec.get('_writes', [])
        rec['_writes'].append((rec[key], idx))
        rec[field] = name

    # --------------------------------------------------------------- write
    def save(self):
        d = bytearray(self.data)

        # 1. pending FName writes into import records (fixed size, no shift)
        for rec in self.imports:
            for at, idx in rec.get('_writes', []):
                struct.pack_into('<q', d, at, idx & 0xFFFFFFFF)

        # 2. rebuild the name table
        blob = bytearray()
        for s in self.names:
            try:
                raw = s.encode('ascii') + b'\0'
                blob += struct.pack('<i', len(raw)) + raw
            except UnicodeEncodeError:
                raw = s.encode('utf-16-le') + b'\0\0'
                blob += struct.pack('<i', -(len(raw) // 2)) + raw
            if self.ue4ver >= 504:
                blob += struct.pack('<HH', strihash(s), strcrc32(s))

        old_len = self.name_table_end - self.name_offset
        delta = len(blob) - old_len
        d[self.name_offset:self.name_table_end] = blob
        struct.pack_into('<i', d, self.name_count_at, len(self.names))

        if delta:
            # 3. every absolute offset after the name table moves
            for label, at in self.i32_fields.items():
                v = struct.unpack_from('<i', d, at)[0]
                if v > self.name_offset:
                    struct.pack_into('<i', d, at, v + delta)
            for label, at in self.i64_fields.items():
                v = struct.unpack_from('<q', d, at)[0]
                if v > self.name_offset:
                    struct.pack_into('<q', d, at, v + delta)
            # 4. and so does every export's data
            for rec in self.exports:
                at = rec['off_at'] + delta
                fmt = '<q' if self.ue4ver >= 511 else '<i'
                v = struct.unpack_from(fmt, d, at)[0]
                if v > self.name_offset:
                    struct.pack_into(fmt, d, at, v + delta)
        return bytes(d)


def selftest(path):
    """Round-trip with no changes must reproduce the file byte for byte."""
    orig = open(path, 'rb').read()
    e = Editor(orig)
    out = e.save()
    same = out == orig
    print('%-56s names=%-4d imports=%-4d exports=%-4d  round-trip %s'
          % (path.split('/')[-1], len(e.names), len(e.imports), len(e.exports),
             'IDENTICAL' if same else 'DIFFERS'))
    if not same:
        diff = [i for i in range(min(len(out), len(orig))) if out[i] != orig[i]]
        print('    %d bytes differ, first at %s, len %d vs %d'
              % (len(diff), diff[:5], len(orig), len(out)))
    return same


if __name__ == '__main__':
    ok = True
    for p in sys.argv[1:]:
        ok &= selftest(p)
    raise SystemExit(0 if ok else 1)
