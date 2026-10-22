#!/usr/bin/env python3
"""
patch-pak.py - replace one file inside an unencrypted UE4 .pak, in place.

Why this exists
---------------
Rebuilding a .pak needs a packer. But if the replacement is *exactly* the same
size as the original and the entry is stored uncompressed, the bytes can be
dropped straight into the existing container. Nothing moves, so no offset in
the index needs recalculating.

Three hashes still have to be repaired, or UE4 refuses to mount the pak:

  1. the SHA1 in the entry header that sits immediately before the file data
  2. the SHA1 in the matching index record
  3. the SHA1 of the whole index, stored in the footer

UE 4.20's FPakFile::LoadIndex hashes the index at mount time and raises a
Fatal error on mismatch, so (3) is not optional.

Usage
-----
  patch-pak.py <file.pak> <path-fragment> <replacement> [--dry-run] [--no-backup]

<path-fragment> is matched against the virtual paths inside the pak and must
select exactly one entry.
"""

import hashlib
import os
import shutil
import struct
import sys

MAGIC = 0x5A6F12E1
FOOTER_MAX = 1024


def die(msg):
    sys.stderr.write('error: %s\n' % msg)
    raise SystemExit(1)


class Reader:
    """Byte cursor that remembers where it is, so field offsets can be captured."""

    def __init__(self, buf, o=0):
        self.b = buf
        self.o = o

    def u8(self):
        v = self.b[self.o]
        self.o += 1
        return v

    def u32(self):
        v = struct.unpack_from('<I', self.b, self.o)[0]
        self.o += 4
        return v

    def i32(self):
        v = struct.unpack_from('<i', self.b, self.o)[0]
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
        if n < 0:                                   # UTF-16
            s = self.raw(-n * 2).decode('utf-16-le')
        else:
            s = self.raw(n).decode('utf-8', 'replace')
        return s.rstrip('\0')


def read_entry(r, version):
    """Parse one FPakEntry. Returns a dict including where its SHA1 lives."""
    e = {'rec_start': r.o}
    e['offset'] = r.i64()
    e['size'] = r.i64()
    e['usize'] = r.i64()
    e['cmethod'] = r.i32()
    if version <= 1:
        r.i64()                                     # timestamp
    e['sha_at'] = r.o                               # <- the field we must fix
    e['sha'] = r.raw(20)
    e['blocks'] = []
    if version >= 3:
        if e['cmethod'] != 0:
            for _ in range(r.i32()):
                e['blocks'].append((r.i64(), r.i64()))
        e['encrypted'] = r.u8()
        e['blocksize'] = r.u32()
    else:
        e['encrypted'] = 0
        e['blocksize'] = 0
    e['rec_end'] = r.o
    return e


def load(path):
    with open(path, 'rb') as f:
        f.seek(0, 2)
        size = f.tell()
        tail = min(size, FOOTER_MAX)
        f.seek(size - tail)
        buf = f.read(tail)
        i = buf.rfind(struct.pack('<I', MAGIC))
        if i < 0:
            die('no pak magic found in the last %d bytes - not a .pak?' % tail)
        magic_at = size - tail + i
        r = Reader(buf, i + 4)
        version = r.u32()
        index_offset = r.i64()
        index_size = r.i64()
        # FPakInfo: magic(4) version(4) indexOffset(8) indexSize(8) indexHash(20)
        index_hash_at = magic_at + 4 + 4 + 8 + 8
        f.seek(index_offset)
        index = f.read(index_size)

    ir = Reader(index)
    mount = ir.fstring()
    count = ir.i32()
    entries = []
    for _ in range(count):
        name = ir.fstring()
        e = read_entry(ir, version)
        e['name'] = name
        entries.append(e)
    return {
        'path': path, 'version': version, 'mount': mount,
        'index_offset': index_offset, 'index_size': index_size,
        'index_hash_at': index_hash_at, 'index': index, 'entries': entries,
    }


def header_size(path, entry, version):
    """The entry header is repeated in the data section; measure it."""
    with open(path, 'rb') as f:
        f.seek(entry['offset'])
        probe = f.read(256)
    hr = Reader(probe)
    read_entry(hr, version)
    return hr.o


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    flags = set(a for a in sys.argv[1:] if a.startswith('--'))
    if len(args) != 3:
        sys.stderr.write(__doc__)
        raise SystemExit(2)
    pak_path, fragment, repl_path = args
    dry = '--dry-run' in flags

    pak = load(pak_path)
    hits = [e for e in pak['entries'] if fragment.lower() in e['name'].lower()]
    if not hits:
        die('no entry matching %r (pak holds %d files)' % (fragment, len(pak['entries'])))
    if len(hits) > 1:
        die('%r is ambiguous:\n  %s' % (fragment, '\n  '.join(e['name'] for e in hits[:10])))
    e = hits[0]

    new = open(repl_path, 'rb').read()
    print('pak      : %s  (v%d, %d files, mount %s)'
          % (os.path.basename(pak_path), pak['version'], len(pak['entries']), pak['mount']))
    print('entry    : %s' % e['name'])
    print('stored   : %d bytes, compression method %d' % (e['size'], e['cmethod']))
    print('new file : %d bytes' % len(new))

    if e['encrypted']:
        die('entry is encrypted - cannot patch in place')
    if e['cmethod'] != 0:
        die('entry is compressed (method %d) - in-place patching needs an uncompressed entry'
            % e['cmethod'])
    if len(new) != e['size'] or len(new) != e['usize']:
        die('size mismatch: entry is %d bytes, replacement is %d. This tool only does '
            'size-neutral patches.' % (e['size'], len(new)))

    hsz = header_size(pak_path, e, pak['version'])
    data_at = e['offset'] + hsz
    sha_in_header_at = e['offset'] + (e['sha_at'] - e['rec_start'])
    new_sha = hashlib.sha1(new).digest()

    print('header   : %d bytes at %d, data at %d' % (hsz, e['offset'], data_at))
    print('sha1     : %s -> %s' % (e['sha'][:8].hex(), new_sha[:8].hex()))

    if dry:
        print('\n--dry-run: nothing written')
        return

    if '--no-backup' not in flags:
        bak = pak_path + '.bak'
        if not os.path.exists(bak):
            shutil.copy2(pak_path, bak)
            print('backup   : %s' % bak)

    # rebuild the index with the new per-entry hash
    index = bytearray(pak['index'])
    index[e['sha_at']:e['sha_at'] + 20] = new_sha
    index_sha = hashlib.sha1(bytes(index)).digest()

    with open(pak_path, 'r+b') as f:
        f.seek(data_at)
        f.write(new)                                   # 1. the file itself
        f.seek(sha_in_header_at)
        f.write(new_sha)                               # 2. entry header hash
        f.seek(pak['index_offset'])
        f.write(bytes(index))                          # 3. index record hash
        f.seek(pak['index_hash_at'])
        f.write(index_sha)                             # 4. hash of the index

    print('index sha: %s' % index_sha[:8].hex())
    print('\npatched in place, size unchanged.')


if __name__ == '__main__':
    main()
