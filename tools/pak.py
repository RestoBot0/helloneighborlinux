#!/usr/bin/env python3
"""Minimal UE4 .pak reader (pak version 4-8, unencrypted index).

Enough to list the index and extract individual records, including
zlib-compressed ones. Written for Hello Neighbor (UE 4.20, pak v5).
"""
import struct, sys, zlib, os

MAGIC = 0x5A6F12E1


class R:
    def __init__(self, b, o=0):
        self.b = b
        self.o = o

    def u8(self):
        v = self.b[self.o]; self.o += 1; return v

    def i32(self):
        v = struct.unpack_from('<i', self.b, self.o)[0]; self.o += 4; return v

    def u32(self):
        v = struct.unpack_from('<I', self.b, self.o)[0]; self.o += 4; return v

    def i64(self):
        v = struct.unpack_from('<q', self.b, self.o)[0]; self.o += 8; return v

    def raw(self, n):
        v = self.b[self.o:self.o + n]; self.o += n; return v

    def fstring(self):
        n = self.i32()
        if n == 0:
            return ''
        if n < 0:                       # UTF-16LE, n is negative char count
            d = self.raw(-n * 2)
            return d.decode('utf-16-le', 'replace').rstrip('\0')
        d = self.raw(n)
        return d.decode('utf-8', 'replace').rstrip('\0')


class Entry:
    __slots__ = ('name', 'offset', 'size', 'usize', 'cmethod',
                 'blocks', 'encrypted', 'blocksize', 'hdr_size')


def read_entry(r, version):
    e = Entry()
    e.offset = r.i64()
    e.size = r.i64()
    e.usize = r.i64()
    e.cmethod = r.i32()
    if version <= 1:
        r.i64()                         # timestamp
    r.raw(20)                           # sha1
    e.blocks = []
    if version >= 3:
        if e.cmethod != 0:
            n = r.i32()
            for _ in range(n):
                e.blocks.append((r.i64(), r.i64()))
        e.encrypted = r.u8()
        e.blocksize = r.u32()
    else:
        e.encrypted = 0
        e.blocksize = 0
    return e


class Pak:
    def __init__(self, path):
        self.path = path
        self.f = open(path, 'rb')
        self.f.seek(0, 2)
        self.size = self.f.tell()
        tail = min(self.size, 1024)
        self.f.seek(self.size - tail)
        buf = self.f.read(tail)
        i = buf.rfind(struct.pack('<I', MAGIC))
        if i < 0:
            raise SystemExit('no pak magic')
        r = R(buf, i + 4)
        self.version = r.u32()
        self.index_offset = r.i64()
        self.index_size = r.i64()
        self.f.seek(self.index_offset)
        idx = R(self.f.read(self.index_size))
        self.mount = idx.fstring()
        n = idx.i32()
        self.entries = []
        for _ in range(n):
            name = idx.fstring()
            e = read_entry(idx, self.version)
            e.name = name
            self.entries.append(e)

    def read(self, e):
        """Return the decompressed bytes of one entry."""
        if e.encrypted:
            raise SystemExit('encrypted entry: ' + e.name)
        # recompute the in-file header size by re-serialising
        self.f.seek(e.offset)
        probe = self.f.read(256)
        hr = R(probe)
        read_entry(hr, self.version)
        data_start = e.offset + hr.o
        if e.cmethod == 0:
            self.f.seek(data_start)
            return self.f.read(e.size)
        out = b''
        for (s, t) in e.blocks:
            # v5+ block offsets are relative to the entry start
            base = e.offset if self.version >= 5 else 0
            self.f.seek(base + s if self.version >= 5 else s)
            if self.version >= 5 and s < e.offset:
                self.f.seek(e.offset + s)
            chunk = self.f.read(t - s)
            try:
                out += zlib.decompress(chunk)
            except zlib.error:
                out += zlib.decompressobj(-15).decompress(chunk)
        return out


if __name__ == '__main__':
    p = Pak(sys.argv[1])
    print(f'mount={p.mount!r}  version={p.version}  entries={len(p.entries)}')
    tot = 0
    for e in p.entries:
        tot += e.usize
        print(f'{e.usize:>12,}  c={e.cmethod}  {e.name}')
    print(f'total uncompressed: {tot:,}')
