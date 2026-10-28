#!/usr/bin/env python3
"""Check that payload.bin, the ADT it embeds and the boot image agree.

  verify_payload.py PAYLOAD ADT BOOT_IMG [--expect-cmdline "debug=0xc"]

Catches the "it built, but the pieces do not match" class of mistake: a stale ADT, a
payload built from another kernel, a boot image that lost the payload, or a cmdline that
never made it into the header.
"""
import struct
import sys

PAGE = 4096
SEG_TABLE = 0x2a8
CMDLINE_OFF = 0x48
CMDLINE_LEN = 608


def payload_header(blob):
    magic = blob[:8]
    version, nsegs = struct.unpack_from('<II', blob, 8)
    virt_base, entry, adt_off, adt_size = struct.unpack_from('<QQQQ', blob, 0x10)
    kernel_end, phys_base, mem_size = struct.unpack_from('<QQQ', blob, 0x30)
    cmdline = blob[CMDLINE_OFF:CMDLINE_OFF + CMDLINE_LEN].split(b'\0')[0].decode('utf-8', 'replace')
    segs = [struct.unpack_from('<4Q', blob, SEG_TABLE + 32 * i) for i in range(nsegs)]
    return dict(magic=magic, version=version, nsegs=nsegs, virt_base=virt_base, entry=entry,
                adt_off=adt_off, adt_size=adt_size, kernel_end=kernel_end,
                phys_base=phys_base, mem_size=mem_size, cmdline=cmdline, segs=segs)


def boot_image(path):
    """Parse the v4 boot image header: kernel size/offset and the arm64 Image header."""
    data = open(path, 'rb').read()
    magic = data[:8]
    kernel_size, = struct.unpack_from('<I', data, 8)
    header_version, = struct.unpack_from('<I', data, 40)
    # v3/v4 keep the kernel at page 1; only the old headers carried an offset field
    kernel_off = 0x1000 if header_version >= 3 else struct.unpack_from('<I', data, 0x10)[0]
    kernel = data[kernel_off:kernel_off + kernel_size]
    image_size, = struct.unpack_from('<Q', kernel, 16)
    return dict(magic=magic, header_version=header_version, total=len(data), kernel_size=kernel_size, kernel_off=kernel_off,
                kernel=kernel, image_size=image_size)


def check(name, cond, detail=''):
    print('  %-52s %s %s' % (name, 'OK' if cond else 'FAIL', detail))
    return cond


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    payload_path, adt_path, boot_path = sys.argv[1:4]
    expect = None
    if '--expect-cmdline' in sys.argv:
        expect = sys.argv[sys.argv.index('--expect-cmdline') + 1]

    ok = True
    blob = open(payload_path, 'rb').read()
    adt = open(adt_path, 'rb').read()
    p = payload_header(blob)
    b = boot_image(boot_path)

    print('payload %d bytes, adt %d bytes, boot image %d bytes' % (len(blob), len(adt), b['total']))
    ok &= check('magic is SWEETXNU', p['magic'] == b'SWEETXNU', p['magic'])
    ok &= check('version 1', p['version'] == 1, str(p['version']))
    ok &= check('has segments', 1 <= p['nsegs'] <= 64, str(p['nsegs']))
    ok &= check('ADT embedded byte for byte',
                blob[p['adt_off']:p['adt_off'] + p['adt_size']] == adt,
                '%d vs %d bytes' % (p['adt_size'], len(adt)))
    ok &= check('ADT inside the payload', p['adt_off'] + p['adt_size'] <= len(blob))

    top = 0
    for i, (vmaddr, vmsize, file_off, file_size) in enumerate(p['segs']):
        good = (file_size <= vmsize and file_off + file_size <= len(blob) and vmsize > 0)
        ok &= check('segment %d consistent' % i, good,
                    'vm %#x off %#x size %#x' % (vmaddr, file_off, file_size))
        top = max(top, vmaddr + vmsize)
    ok &= check('kernel_end follows the segments', p['kernel_end'] >= top,
                '%#x vs %#x' % (p['kernel_end'], top))
    ok &= check('kernel_end is page aligned', p['kernel_end'] % 0x4000 == 0)
    ok &= check('phys_base/mem_size set', p['phys_base'] != 0 and p['mem_size'] != 0,
                '%#x/%#x' % (p['phys_base'], p['mem_size']))

    ok &= check('boot image magic ANDROID!', b['magic'] == b'ANDROID!', b['magic'])
    ok &= check('boot image carries a kernel', b['kernel_size'] > 0, str(b['kernel_size']))
    ok &= check('arm64 Image header sane', b['kernel'][0x38:0x3c] == b'ARM\x64')
    ok &= check('image_size matches the payload', b['image_size'] == len(b['kernel']),
                '%#x vs %#x' % (b['image_size'], len(b['kernel'])))
    ok &= check('boot image contains the payload', b['kernel'].find(blob[:64]) > 0)

    if expect:
        ok &= check('cmdline has the expected tokens',
                    all(tok in p['cmdline'] for tok in expect.split()),
                    p['cmdline'][:70])

    print('\n%s' % ('CHAIN OK' if ok else 'CHAIN MISMATCH'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
