#!/usr/bin/env python3
"""
rebuild-pak.py - write a new UE4 .pak, optionally swapping files in.

patch-pak.py can only do same-size replacements. Once an asset grows - adding
a name to its name table, say - the whole container has to be laid out again.
That is what this does.

A v5 pak is simpler than it looks:

    for each file:  FPakEntry record (53 bytes, Offset field zeroed)
                    the file bytes
    index:          mount point, file count, then
                    filename + FPakEntry record (real Offset) per file
    footer:         bEncryptedIndex, magic, version,
                    index offset, index size, SHA1 of the index

Every SHA1 is recomputed from the bytes actually written, so a rebuilt pak is
self-consistent by construction.

Usage:
  rebuild-pak.py <in.pak> <out.pak> [--replace PATH=FILE]... [--add PATH=FILE]...

PATH is matched as a suffix of the virtual path inside the pak, so
"BP_Cat_hat.uasset" is usually enough.
"""

import hashlib
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import importlib.util
_spec = importlib.util.spec_from_file_location('pp', os.path.join(HERE, 'patch-pak.py'))
pp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pp)

MAGIC = 0x5A6F12E1


def die(m):
    sys.stderr.write('error: %s\n' % m)
    raise SystemExit(1)


def fstring(s):
    raw = s.encode('utf-8') + b'\0'
    return struct.pack('<i', len(raw)) + raw


def entry_record(offset, size, sha):
    """FPakEntry for a stored-uncompressed file: 53 bytes."""
    return (struct.pack('<qqq', offset, size, size)   # offset, size, uncompressed
            + struct.pack('<i', 0)                     # compression method: none
            + sha                                      # 20 bytes
            + struct.pack('<B', 0)                     # not encrypted
            + struct.pack('<I', 0))                    # compression block size


def build(files, mount, version=5):
    """files: list of (virtual_path, bytes). Returns the whole pak."""
    body = bytearray()
    records = []
    for name, data in files:
        sha = hashlib.sha1(data).digest()
        offset = len(body)
        body += entry_record(0, len(data), sha)        # header copy: offset zeroed
        body += data
        records.append((name, offset, len(data), sha))

    index = bytearray()
    index += fstring(mount)
    index += struct.pack('<i', len(records))
    for name, offset, size, sha in records:
        index += fstring(name)
        index += entry_record(offset, size, sha)

    index_offset = len(body)
    footer = (struct.pack('<B', 0)                     # bEncryptedIndex
              + struct.pack('<I', MAGIC)
              + struct.pack('<I', version)
              + struct.pack('<q', index_offset)
              + struct.pack('<q', len(index))
              + hashlib.sha1(bytes(index)).digest())
    return bytes(body) + bytes(index) + footer


def collect(flag):
    out = []
    argv = sys.argv[1:]
    for i, a in enumerate(argv):
        if a == flag and i + 1 < len(argv):
            out.append(argv[i + 1])
        elif a.startswith(flag + '='):
            out.append(a.split('=', 1)[1])
    return out


def main():
    plain, skip = [], False
    for a in sys.argv[1:]:
        if skip:
            skip = False
            continue
        if a.startswith('--'):
            if '=' not in a:
                skip = True
            continue
        plain.append(a)
    if len(plain) != 2:
        sys.stderr.write(__doc__)
        raise SystemExit(2)
    src, dst = plain

    repl = {}
    for spec in collect('--replace') + collect('--add'):
        if '=' not in spec:
            die('expected PATH=FILE, got %r' % spec)
        k, v = spec.split('=', 1)
        if not os.path.isfile(v):
            die('no such file: %s' % v)
        repl[k] = v

    pak = pp.load(src)
    print('source : %s  (v%d, %d files, mount %s)'
          % (os.path.basename(src), pak['version'], len(pak['entries']), pak['mount']))

    files = []
    used = set()
    with open(src, 'rb') as f:
        for e in pak['entries']:
            if e['cmethod'] != 0 or e['encrypted']:
                die('%s is compressed or encrypted; unsupported' % e['name'])
            f.seek(e['offset'])
            hr = pp.Reader(f.read(256))
            pp.read_entry(hr, pak['version'])
            f.seek(e['offset'] + hr.o)
            data = f.read(e['size'])
            for frag, path in repl.items():
                if e['name'].endswith(frag) or frag == e['name']:
                    new = open(path, 'rb').read()
                    print('  replace %s' % e['name'])
                    print('          %d -> %d bytes  (%+d)'
                          % (len(data), len(new), len(new) - len(data)))
                    data = new
                    used.add(frag)
                    break
            files.append((e['name'], data))

    missing = set(repl) - used
    if missing:
        die('these did not match anything in the pak: %s' % ', '.join(sorted(missing)))

    out = build(files, pak['mount'], pak['version'])
    with open(dst, 'wb') as f:
        f.write(out)
    print('\nwrote  : %s  (%d bytes)' % (dst, len(out)))

    # --- verify what we just wrote, the way the engine would ---
    chk = pp.load(dst)
    bad = []
    with open(dst, 'rb') as f:
        for e in chk['entries']:
            f.seek(e['offset'])
            hr = pp.Reader(f.read(256))
            h = pp.read_entry(hr, chk['version'])
            f.seek(e['offset'] + hr.o)
            if hashlib.sha1(f.read(e['size'])).digest() != e['sha']:
                bad.append(e['name'])
            if h['sha'] != e['sha'] or h['size'] != e['size']:
                bad.append(e['name'] + ' (header)')
        f.seek(chk['index_hash_at'])
        stored = f.read(20)
    print('verify : %d files, content hashes %s, index hash %s'
          % (len(chk['entries']),
             'OK' if not bad else bad[:3],
             'OK' if stored == hashlib.sha1(chk['index']).digest() else 'BAD'))
    if bad or stored != hashlib.sha1(chk['index']).digest():
        die('verification failed - do not install this')


if __name__ == '__main__':
    main()
