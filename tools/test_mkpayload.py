#!/usr/bin/env python3
"""Tests for mkpayload.py: a good kernel packs, a broken one is refused with a reason.

Synthetic Mach-O files only; nothing here needs a real kernel or a phone.

Run from the fork's work/ directory:  python ../scripts/test-mkpayload.py
"""
import os
import struct
import subprocess
import sys
import tempfile

MKPAYLOAD = os.path.join('tools', 'mkpayload.py')
MKADT = os.path.join('tools', 'mkadt_pandora.py')

LC_SEGMENT_64, LC_UNIXTHREAD = 0x19, 0x5


def macho(text_name=b'__TEXT', text_fileoff=0, entry=0x80001000, magic=0xfeedfacf,
          omit_thread=False):
    """Build a minimal Mach-O with one segment; knobs make it wrong on purpose."""
    text_off, text_size, vmaddr = 0x4000, 0x8000, 0x80000000
    seg = struct.pack('<II', LC_SEGMENT_64, 72)
    seg += text_name.ljust(16, b'\0')
    seg += struct.pack('<4Q', vmaddr, text_off + text_size, text_fileoff, text_off + text_size)
    seg += struct.pack('<II', 7, 5)
    seg += struct.pack('<II', 0, 0)

    cmds = seg
    if not omit_thread:
        thread = struct.pack('<II', LC_UNIXTHREAD, 16 + 34 * 8)
        thread += struct.pack('<II', 6, 68)
        regs = [0] * 34
        regs[32] = entry
        thread += struct.pack('<34Q', *regs)
        cmds += thread

    ncmds = 1 + (0 if omit_thread else 1)
    hdr = struct.pack('<8I', magic, 0x0100000c, 0, 2, ncmds, len(cmds), 0, 0)
    body = bytearray(text_off + text_size)
    body[:32] = hdr
    body[32:32 + len(cmds)] = cmds
    return bytes(body)


def run(kernel_bytes, adt_path):
    with tempfile.TemporaryDirectory() as tmp:
        kpath = os.path.join(tmp, 'kernel')
        open(kpath, 'wb').write(kernel_bytes)
        out = os.path.join(tmp, 'payload.bin')
        proc = subprocess.run([sys.executable, MKPAYLOAD, kpath, adt_path, out,
                               '--cmdline', 'debug=0xc test=1'],
                              capture_output=True, text=True)
        blob = open(out, 'rb').read() if os.path.exists(out) else None
        return proc.returncode, (proc.stderr or '') + (proc.stdout or ''), blob


def check(name, cond, detail=''):
    print('%-56s %s %s' % (name, 'PASS' if cond else 'FAIL', detail))
    return cond


def main():
    ok = True
    with tempfile.TemporaryDirectory() as tmp:
        adt = os.path.join(tmp, 'phone.adt')
        subprocess.run([sys.executable, MKADT, adt], check=True, capture_output=True)

        rc, msg, blob = run(macho(entry=0x80001000), adt)
        ok &= check('valid Mach-O packs', rc == 0 and blob is not None, 'rc=%d' % rc)
        if blob:
            magic = blob[:8]
            ver, nsegs = struct.unpack_from('<II', blob, 8)
            virt_base, entry = struct.unpack_from('<QQ', blob, 0x10)
            cmdline = blob[0x48:0x48 + 608].split(b'\0')[0].decode()
            ok &= check('  magic/version/nsegs', (magic, ver, nsegs) == (b'SWEETXNU', 1, 1))
            ok &= check('  virt_base is the 32 MiB-aligned header base',
                        virt_base == 0x80000000, hex(virt_base))
            ok &= check('  entry copied', entry == 0x80001000, hex(entry))
            ok &= check('  cmdline embedded', cmdline == 'debug=0xc test=1', repr(cmdline))

        cases = [
            ('garbage input refused', b'not a mach-o' * 100, 'not a 64-bit Mach-O'),
            ('32-bit Mach-O refused', macho(magic=0xfeedface), 'not a 64-bit Mach-O'),
            ('segment not named __TEXT refused', macho(text_name=b'__DATA'), '__TEXT'),
            ('__TEXT not at file offset 0 refused', macho(text_fileoff=0x4000), 'file offset 0'),
            ('missing LC_UNIXTHREAD refused', macho(omit_thread=True), 'LC_UNIXTHREAD'),
        ]
        for name, data, expect in cases:
            rc, msg, blob = run(data, adt)
            ok &= check(name, rc != 0 and blob is None and expect in msg,
                        'rc=%d %s' % (rc, 'msg-ok' if expect in msg else msg.strip().splitlines()[-1][:60]))

    print('\n%s' % ('ALL PASS' if ok else 'SOME FAILED'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
