#!/usr/bin/env python3
"""Build a minimal 64-bit Mach-O that mkpayload.py accepts, for chain dry runs.

Not a kernel: one __TEXT segment, no chained fixups, entry point set.
"""
import struct
import sys

out = sys.argv[1]
text_off = 0x4000
text_size = 0x8000
vmaddr = 0x80000000

LC_SEGMENT_64, LC_UNIXTHREAD = 0x19, 0x5

seg = struct.pack('<II', LC_SEGMENT_64, 72)
seg += b'__TEXT'.ljust(16, b'\0')
seg += struct.pack('<4Q', vmaddr, text_off + text_size, 0, text_off + text_size)  # __TEXT must start at file offset 0
seg += struct.pack('<II', 7, 5)          # maxprot rwx, initprot rx
seg += struct.pack('<II', 0, 0)          # nsects, flags
assert len(seg) == 72, len(seg)

thread = struct.pack('<II', LC_UNIXTHREAD, 16 + 34 * 8)
thread += struct.pack('<II', 6, 68)      # flavor ARM_THREAD_STATE64, count (u32 words)
regs = [0] * 34
regs[32] = vmaddr + 0x1000               # pc
thread += struct.pack('<34Q', *regs)
assert len(thread) == 16 + 34 * 8, len(thread)

sizeofcmds = len(seg) + len(thread)
hdr = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 2, 2, sizeofcmds, 0, 0)

body = bytearray(text_off + text_size)
body[:32] = hdr
body[32:32 + len(seg)] = seg
body[32 + len(seg):32 + sizeofcmds] = thread
for i in range(text_off, text_off + text_size):
    body[i] = i & 0xff

with open(out, 'wb') as f:
    f.write(body)
print('%s %d bytes, sizeofcmds %d, text at %#x, vmaddr %#x, pc %#x' % (
    out, len(body), sizeofcmds, text_off, vmaddr, vmaddr + 0x1000))
