#!/usr/bin/env python3
"""Malformed-input tests for mkadt_pandora.py's --root-extents.

A wrong extent table produces a bootable-looking payload that dies in the kernel, which
is far harder to diagnose than a refusal here. Every bad table must fail loudly and
leave no output file, and a good one must encode exactly the triples we gave it.

Run from the fork's work/ directory:  python ../scripts/test-adt-extents.py
"""
import json
import os
import struct
import subprocess
import sys
import tempfile

MKADT = os.path.join('tools', 'mkadt_pandora.py')
MIB = 1024 * 1024


def run(table, size_override=None):
    """Run mkadt with this extent table; return (exit code, output, adt bytes or None)."""
    with tempfile.TemporaryDirectory() as tmp:
        table = dict(table)
        if size_override is not None:
            table['size'] = size_override
        jpath = os.path.join(tmp, 'ext.json')
        with open(jpath, 'w') as f:
            json.dump(table, f)
        out = os.path.join(tmp, 'out.adt')
        proc = subprocess.run([sys.executable, MKADT, out, '--root-extents', jpath],
                              capture_output=True, text=True)
        blob = open(out, 'rb').read() if os.path.exists(out) else None
        return proc.returncode, (proc.stderr or '') + (proc.stdout or ''), blob


def chosen_prop(blob, name):
    """Pull one /chosen property out of the ADT: name[32] is followed by a u32 length."""
    i = blob.find(name.encode())
    if i < 0:
        return None
    length, = struct.unpack_from('<I', blob, i + 32)
    return blob[i + 36:i + 36 + length]


def check(name, cond, detail=''):
    print('%-56s %s %s' % (name, 'PASS' if cond else 'FAIL', detail))
    return cond


def main():
    ok = True
    ext = [[0, 0, 4 * MIB, 0], [4 * MIB, 8 * MIB, 4 * MIB, 0]]
    good = {'size': 8 * MIB, 'extents': ext}

    rc, msg, blob = run(good)
    ok &= check('valid table accepted', rc == 0 and blob is not None, 'rc=%d' % rc)

    if blob:
        blocks = chosen_prop(blob, 'fuxi-root-blocks')
        ok &= check('fuxi-root-blocks == size / 4 KiB',
                    blocks == struct.pack('<Q', 8 * MIB // 4096),
                    '' if blocks is None else hex(struct.unpack('<Q', blocks)[0]))

        raw = chosen_prop(blob, 'fuxi-root-extents')
        triples = [] if raw is None else [struct.unpack_from('<3Q', raw, i)
                                          for i in range(0, len(raw), 24)]
        want = [(0, 0, 1024), (1024, 2048, 1024)]
        ok &= check('triples are {file,part,count} in 4 KiB units', triples == want, '%r' % (triples,))

        ok &= check('product node kept (unique-chip-id)',
                    chosen_prop(blob, 'unique-chip-id') is not None)
        totals = sum(t[2] for t in triples)
        ok &= check('triples cover the root exactly', totals == 8 * MIB // 4096, '%d blocks' % totals)

    cases = [
        ('logical gap', {'size': 8 * MIB, 'extents': [[0, 0, 4 * MIB, 0], [8 * MIB, 8 * MIB, 4 * MIB, 0]]},
         'not contiguous'),
        ('physical not 4 KiB aligned', {'size': 4 * MIB, 'extents': [[0, 512, 4 * MIB, 0]]},
         'not contiguous 4 KiB'),
        ('length not 4 KiB aligned', {'size': 4 * MIB, 'extents': [[0, 0, 4 * MIB + 8, 0]]},
         'not contiguous 4 KiB'),
        ('zero-length extent', {'size': 4 * MIB, 'extents': [[0, 0, 0, 0], [0, 4 * MIB, 4 * MIB, 0]]},
         'not contiguous 4 KiB'),
        ('extents do not cover the root', {'size': 8 * MIB, 'extents': [[0, 0, 4 * MIB, 0]]},
         'do not cover'),
        ('root size not 4 KiB aligned', {'size': 4 * MIB, 'extents': [[0, 0, 4 * MIB, 0]]},
         'aligned'),
    ]
    root_sizes = {'root size not 4 KiB aligned': 4 * MIB + 1}
    for name, table, expect in cases:
        rc, msg, blob = run(table, size_override=root_sizes.get(name))
        ok &= check(name + ' rejected', rc != 0 and blob is None and expect in msg,
                    'rc=%d %s' % (rc, 'msg-ok' if expect in msg else msg.strip().splitlines()[-1][:60]))

    print('\n%s' % ('ALL PASS' if ok else 'SOME FAILED'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
