#!/usr/bin/env python3
"""
rename-mod.py - turn a Hello Neighbor mod into a separate, differently-named mod.

A mod's name is not just the folder. It is baked into every asset path inside
the .pak (/OldName/Sounds/Foo, /OldName/Materials/Bar, ...) - in FoxyReignited
that is 1,731 occurrences. Those strings are length-prefixed, so shortening or
lengthening the name would shift thousands of offsets and break the mod.

Keep the new name the SAME NUMBER OF CHARACTERS and every replacement is a
straight byte swap: nothing moves, nothing needs recalculating. This script
enforces that.

It rewrites, for the copy it produces:
  - the folder name
  - the .uplugin filename, and its FriendlyName / Description / CreatedBy
  - the .pak filename
  - every occurrence of the old name inside the .pak
  - all three layers of SHA1 that UE4 validates at mount time

Usage:
  rename-mod.py <mod-folder> <NewName> [options]

Options:
  --out DIR          where to write the new mod folder   (default: alongside)
  --title TEXT       FriendlyName shown in the mod menu  (default: NewName)
  --desc TEXT        Description shown in the mod menu
  --author TEXT      CreatedBy
  --version TEXT     VersionName
  --dry-run          report only, write nothing

Please leave the original author credited somewhere. Renaming someone's mod
and passing it off as your own is the one thing mod communities genuinely
mind; a personal retune that still says who built it is fine.
"""

import hashlib
import json
import os
import re
import shutil
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import importlib.util
_spec = importlib.util.spec_from_file_location('pp', os.path.join(HERE, 'patch-pak.py'))
pp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pp)


def die(msg):
    sys.stderr.write('error: %s\n' % msg)
    raise SystemExit(1)


def getopt(name, default=None):
    flag = '--' + name
    argv = sys.argv[1:]
    for i, a in enumerate(argv):
        if a == flag and i + 1 < len(argv):
            return argv[i + 1]
        if a.startswith(flag + '='):
            return a.split('=', 1)[1]
    return default


def rewrite_pak(path, old, new, dry=False):
    """Byte-swap the mod name throughout a pak and repair every hash."""
    pak = pp.load(path)
    ob, nb = old.encode(), new.encode()

    with open(path, 'rb') as f:
        raw = bytearray(f.read())

    total = 0
    touched = 0
    index = bytearray(pak['index'])

    for e in pak['entries']:
        if e['encrypted'] or e['cmethod'] != 0:
            die('entry %s is compressed or encrypted; this script needs an '
                'uncompressed pak' % e['name'])
        hr = pp.Reader(bytes(raw[e['offset']:e['offset'] + 256]))
        pp.read_entry(hr, pak['version'])
        start = e['offset'] + hr.o
        blob = bytes(raw[start:start + e['size']])
        n = blob.count(ob)
        if n == 0:
            continue
        newblob = blob.replace(ob, nb)
        if len(newblob) != len(blob):
            die('internal: replacement changed the size of %s' % e['name'])
        total += n
        touched += 1
        if dry:
            continue
        raw[start:start + e['size']] = newblob
        sha = hashlib.sha1(newblob).digest()
        # the entry header repeats the record just before the data
        sha_hdr = e['offset'] + (e['sha_at'] - e['rec_start'])
        raw[sha_hdr:sha_hdr + 20] = sha
        index[e['sha_at']:e['sha_at'] + 20] = sha

    # the index also stores the virtual path of every file
    idx_hits = index.count(ob)
    index = bytearray(bytes(index).replace(ob, nb))
    if len(index) != pak['index_size']:
        die('internal: index changed size')

    print('    %d occurrences in %d of %d files, %d in the file list'
          % (total, touched, len(pak['entries']), idx_hits))
    if dry:
        return total + idx_hits

    raw[pak['index_offset']:pak['index_offset'] + pak['index_size']] = index
    ih = hashlib.sha1(bytes(index)).digest()
    raw[pak['index_hash_at']:pak['index_hash_at'] + 20] = ih

    with open(path, 'wb') as f:
        f.write(bytes(raw))
    return total + idx_hits


def main():
    args = []
    skip = False
    argv = sys.argv[1:]
    for i, a in enumerate(argv):
        if skip:
            skip = False
            continue
        if a.startswith('--'):
            if '=' not in a and a not in ('--dry-run',):
                skip = True
            continue
        args.append(a)
    if len(args) != 2:
        sys.stderr.write(__doc__)
        raise SystemExit(2)

    src, new = args
    dry = '--dry-run' in argv
    src = src.rstrip('/')
    if not os.path.isdir(src):
        die('not a folder: %s' % src)

    uplugins = [f for f in os.listdir(src) if f.endswith('.uplugin')]
    if len(uplugins) != 1:
        die('expected exactly one .uplugin in %s, found %d' % (src, len(uplugins)))
    old = uplugins[0][:-len('.uplugin')]

    if not re.fullmatch(r'[A-Za-z0-9_]+', new):
        die('the new name must be letters, digits and underscores only')
    if len(new) != len(old):
        die('"%s" is %d characters but "%s" is %d.\n'
            'They must match exactly, or the asset paths inside the pak shift '
            'and the mod breaks.\nPick a name of exactly %d characters.'
            % (new, len(new), old, len(old), len(old)))

    out_parent = getopt('out') or os.path.dirname(os.path.abspath(src))
    dest = os.path.join(out_parent, new)

    print('renaming : %s -> %s  (%d characters, lengths match)' % (old, new, len(old)))
    print('source   : %s' % src)
    print('dest     : %s' % dest)

    if dry:
        print('\n[dry run] pak contents:')
        pak_src = os.path.join(src, 'Content', 'Paks', 'WindowsNoEditor', old + '.pak')
        if os.path.isfile(pak_src):
            rewrite_pak(pak_src, old, new, dry=True)
        print('\nnothing written')
        return

    if os.path.exists(dest):
        die('%s already exists - move it aside first' % dest)
    os.makedirs(out_parent, exist_ok=True)
    print('\ncopying...')
    shutil.copytree(src, dest)

    # --- .uplugin -------------------------------------------------------
    up_old = os.path.join(dest, old + '.uplugin')
    up_new = os.path.join(dest, new + '.uplugin')
    with open(up_old, 'r', encoding='utf-8-sig') as f:
        meta = json.load(f)
    orig_author = meta.get('CreatedBy', '')
    meta['FriendlyName'] = getopt('title') or new
    if getopt('desc'):
        meta['Description'] = getopt('desc')
    if getopt('author'):
        meta['CreatedBy'] = getopt('author')
    if getopt('version'):
        meta['VersionName'] = getopt('version')
    os.rename(up_old, up_new)
    with open(up_new, 'w', encoding='utf-8', newline='\r\n') as f:
        json.dump(meta, f, indent='\t')
        f.write('\n')
    print('uplugin  : %s' % os.path.basename(up_new))
    print('           FriendlyName = %s' % meta['FriendlyName'])
    print('           CreatedBy    = %s' % meta.get('CreatedBy', ''))
    if orig_author and meta.get('CreatedBy') != orig_author:
        print('           (original author was %s)' % orig_author)

    # --- the pak --------------------------------------------------------
    pak_dir = os.path.join(dest, 'Content', 'Paks', 'WindowsNoEditor')
    pak_old = os.path.join(pak_dir, old + '.pak')
    pak_new = os.path.join(pak_dir, new + '.pak')
    if not os.path.isfile(pak_old):
        die('no %s.pak under %s' % (old, pak_dir))
    os.rename(pak_old, pak_new)
    print('pak      : %s' % os.path.basename(pak_new))
    rewrite_pak(pak_new, old, new)

    # --- verify ---------------------------------------------------------
    print('\nverifying...')
    pak = pp.load(pak_new)
    bad = []
    with open(pak_new, 'rb') as f:
        for e in pak['entries']:
            f.seek(e['offset'])
            hr = pp.Reader(f.read(256))
            h = pp.read_entry(hr, pak['version'])
            f.seek(e['offset'] + hr.o)
            if hashlib.sha1(f.read(e['size'])).digest() != e['sha']:
                bad.append(e['name'])
            if h['sha'] != e['sha']:
                bad.append(e['name'] + ' (header)')
        f.seek(pak['index_hash_at'])
        stored = f.read(20)
    ok_index = stored == hashlib.sha1(pak['index']).digest()
    leftover = sum(1 for e in pak['entries'] if old.lower() in e['name'].lower())

    print('  content + header hashes : %s' % ('OK' if not bad else bad[:3]))
    print('  index hash              : %s' % ('OK' if ok_index else 'BAD'))
    print('  paths still saying %-5s: %d' % (old[:5], leftover))
    print('  size                    : %d bytes' % os.path.getsize(pak_new))
    if bad or not ok_index or leftover:
        die('verification failed - do not install this')
    print('\nDone. Drop this folder into HelloNeighbor/Mods/')


if __name__ == '__main__':
    main()
