#!/usr/bin/env python3
"""
registry-trim.py - drop an asset from a cooked AssetRegistry.bin.

Hello Neighbor's Modding menu lists neighbours by asset. FoxyReignited ships
two of them, so the menu shows a second entry nobody wants.

Deleting the .uasset is the obvious move and the wrong one: ten other files in
the mod import that class, and the registry would still advertise an asset
whose file is gone. Removing only the *registry entry* takes it off the list
while every existing reference still resolves. If the menu turns out not to be
built from the registry, nothing breaks - the file is untouched.

Layout of a cooked AssetRegistry.bin (UE4.20, version 5):

    0   16 bytes  FAssetRegistryVersion GUID
    16  int32     version (5)
    20  int64     offset of the name table
    28  int32     number of assets
        ...       that many FAssetData records
        ...       trailing section (dependency + package data counts)
    N   int32     name count, then <int32 len><chars><uint16><uint16> entries

and one FAssetData record is:

    FName  ObjectPath, PackagePath, AssetClass, PackageName, AssetName
    int32  tag count, then that many <FName key><FString value>
    int32  chunk count, then that many int32
    uint32 PackageFlags

FNames here are an int32 index into the name table plus an int32 number. The
name table is left exactly as it is: the indices of every surviving record
have to keep pointing at the same strings, and a few unreferenced names cost
nothing.

Usage:
  registry-trim.py <AssetRegistry.bin> <out.bin> --drop SUBSTRING [--drop ...]
  registry-trim.py <AssetRegistry.bin> --list
"""

import importlib.util
import os
import struct
import sys

GUID = bytes.fromhex('e79e7f713a49b0e93291b3880781381b')

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    'ue_hash', os.path.join(_HERE, 'uasset_edit.py'))
_ue = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_ue)
_strihash, _strcrc32 = _ue.strihash, _ue.strcrc32


def die(msg):
    sys.stderr.write('error: %s\n' % msg)
    raise SystemExit(1)


class Registry:
    def __init__(self, data):
        self.data = data
        if data[:16] != GUID:
            die('not an AssetRegistry.bin (wrong header guid)')
        self.version = struct.unpack_from('<i', data, 16)[0]
        self.name_offset = struct.unpack_from('<q', data, 20)[0]
        self._read_names()
        self._read_assets()

    def _read_names(self):
        d, o = self.data, self.name_offset
        count = struct.unpack_from('<i', d, o)[0]
        o += 4
        self.names = []
        for _ in range(count):
            ln = struct.unpack_from('<i', d, o)[0]
            o += 4
            if ln < 0:
                self.names.append(d[o:o - 2 * ln - 2].decode('utf-16-le'))
                o += -2 * ln
            else:
                self.names.append(d[o:o + ln - 1].decode('latin1'))
                o += ln
            o += 4                                  # the two uint16 hashes
        if o != len(d):
            die('name table ended at %d, file is %d bytes' % (o, len(d)))

    def _read_assets(self):
        d = self.data
        self.o = 28
        self.count = struct.unpack_from('<i', d, self.o)[0]
        self.o += 4
        self.assets = []
        self.tags = []
        for i in range(self.count):
            start = self.o
            path = self._fname()
            for _ in range(4):                      # PackagePath..AssetName
                self._fname()
            ntags = self._i32()
            tags = []
            for _ in range(ntags):
                tags.append((self._fname(), self._fstring()))
            # Deliberately two statements. "self.o += 4 * self._i32()" loads
            # self.o before _i32() advances it, so the count's own four bytes
            # get dropped and every later record is misread.
            nchunks = self._i32()
            self.o += 4 * nchunks                   # chunk ids
            self.o += 4                             # PackageFlags
            if self.o > self.name_offset:
                die('asset %d ran past the name table' % i)
            self.assets.append((path, start, self.o))
            self.tags.append(tags)
        self.tail = d[self.o:self.name_offset]

    def _i32(self):
        v = struct.unpack_from('<i', self.data, self.o)[0]
        self.o += 4
        return v

    def _fname(self):
        i, n = struct.unpack_from('<ii', self.data, self.o)
        self.o += 8
        if not (0 <= i < len(self.names)):
            die('name index %d out of range' % i)
        return self.names[i] if n == 0 else '%s_%d' % (self.names[i], n - 1)

    def _fstring(self):
        ln = struct.unpack_from('<i', self.data, self.o)[0]
        self.o += 4
        if ln < 0:
            s = self.data[self.o:self.o - 2 * ln - 2].decode('utf-16-le')
            self.o += -2 * ln
        else:
            s = self.data[self.o:self.o + ln - 1].decode('latin1') if ln else ''
            self.o += ln
        return s

    def name_id(self, text):
        """Index of a name, appending it to the table if new."""
        if text not in self.names:
            self.names.append(text)
        return self.names.index(text)

    def clone_record(self, like, newpath, newpkg, newname, retag=()):
        """Copy an existing record, repointing its five FNames and any tag
        whose value mentions the old package. Used to advertise an asset that
        was added to the pak, so the Modding menu can see it."""
        src = [i for i, (p, _, _) in enumerate(self.assets) if p == like]
        if len(src) != 1:
            die('template %r matched %d records' % (like, len(src)))
        i = src[0]
        _, start, end = self.assets[i]
        head = self.data[start:start + 40]            # five FNames
        rest = self.data[start + 40:end]
        old_names = struct.unpack_from('<10i', head)
        rec = bytearray()
        rec += struct.pack('<ii', self.name_id(newpath), old_names[1])
        rec += struct.pack('<ii', old_names[2], old_names[3])   # PackagePath
        rec += struct.pack('<ii', old_names[4], old_names[5])   # AssetClass
        rec += struct.pack('<ii', self.name_id(newpkg), old_names[7])
        rec += struct.pack('<ii', self.name_id(newname), old_names[9])
        # rebuild the tag block so values can change length
        tags = [(k, dict(retag).get(k, v)) for k, v in self.tags[i]]
        body = bytearray(struct.pack('<i', len(tags)))
        for k, v in tags:
            body += struct.pack('<ii', self.name_id(k), 0)
            body += struct.pack('<i', len(v) + 1) + v.encode('latin1') + b'\0'
        # chunk ids + PackageFlags copied verbatim from the tail of the source
        o = start + 40
        o += 4
        for _ in range(self.tags[i].__len__()):
            o += 8
            ln = struct.unpack_from('<i', self.data, o)[0]
            o += 4 + (ln if ln >= 0 else -2 * ln)
        body += self.data[o:end]
        self.extra = getattr(self, 'extra', b'') + bytes(rec) + bytes(body)
        return len(self.names)

    def build(self, drop_spans=()):
        """Reassemble the file without the given (start, end) records."""
        d = self.data
        keep = [a for a in self.assets if (a[1], a[2]) not in drop_spans]
        body = b''.join(d[s:e] for _, s, e in keep)
        out = bytearray()
        out += d[:16]
        out += struct.pack('<i', self.version)
        out += struct.pack('<q', 0)                 # patched below
        extra = getattr(self, 'extra', b'')
        out += struct.pack('<i', len(keep) + (1 if extra else 0))
        out += body
        out += extra
        out += self.tail
        struct.pack_into('<q', out, 20, len(out))   # name table moves up
        tbl = bytearray(struct.pack('<i', len(self.names)))
        for text in self.names:
            raw = text.encode('latin1')
            tbl += struct.pack('<i', len(raw) + 1) + raw + b'\0'
            tbl += struct.pack('<HH', _strihash(text) & 0xFFFF,
                               _strcrc32(text) & 0xFFFF)
        out += tbl
        return bytes(out)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    drops = [sys.argv[i + 1] for i, a in enumerate(sys.argv) if a == '--drop']
    drops += [a.split('=', 1)[1] for a in sys.argv if a.startswith('--drop=')]

    if not args:
        sys.stderr.write(__doc__)
        raise SystemExit(2)

    reg = Registry(open(args[0], 'rb').read())
    print('%s: version %d, %d assets, %d names'
          % (os.path.basename(args[0]), reg.version, reg.count, len(reg.names)))

    if '--list' in sys.argv:
        for path, s, e in reg.assets:
            print('   %7d  %s' % (e - s, path))
        return

    if len(args) != 2:
        die('need an output path, or --list')
    if not drops:
        die('nothing to drop (use --drop SUBSTRING)')

    spans, gone = set(), []
    for path, s, e in reg.assets:
        if any(sub in path for sub in drops):
            spans.add((s, e))
            gone.append(path)
    if not gone:
        die('no asset matched %s' % drops)
    for path in gone:
        print('   drop  %s' % path)

    out = reg.build(spans)

    # read it back from scratch - the only check that means anything
    back = Registry(out)
    if back.count != reg.count - len(gone):
        die('rebuilt count is %d, expected %d' % (back.count, reg.count - len(gone)))
    if back.o != back.name_offset - len(back.tail):
        die('rebuilt asset table does not meet the tail')
    before = [p for p, _, _ in reg.assets if p not in gone]
    after = [p for p, _, _ in back.assets]
    if before != after:
        die('the surviving assets are not the same, or not in the same order')
    if back.names != reg.names:
        die('the name table changed')
    if back.tail != reg.tail:
        die('the trailing section changed')

    open(args[1], 'wb').write(out)
    print('wrote %s: %d assets, %d bytes (was %d)'
          % (args[1], back.count, len(out), len(reg.data)))
    print('re-read clean: same names, same tail, same surviving assets in order')


if __name__ == '__main__':
    main()
