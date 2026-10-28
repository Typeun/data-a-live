#!/usr/bin/env python3
"""Port of myron_touch.c's parser selection, with unit tests.

Mirrors mt_points/mt_scale/mt_poll so the scoring logic can be exercised against real
idle frames and synthetic ones without booting anything.

Rule under test: without an explicit myron_touch_max_x/y the IC's words are panel pixels,
so anything outside 0..1199 / 0..2607 is a misparse and must not become a touch.
"""
import sys

PT_MAX = 10
FTS_POINTS_MAX = 10
PANEL_W, PANEL_H = 1200, 2608


def scale(raw, panel, override):
    if override:
        return min(raw * panel // override, panel - 1)
    return min(raw, panel - 1)


def points(buf, count, stride, override_x=0, override_y=0):
    lim_x = override_x or PANEL_W
    lim_y = override_y or PANEL_H
    out, mask = [], 0
    for i in range(count):
        q = buf[1 + stride * i:]
        if len(q) < stride:
            break
        if stride == 6:
            tid = q[0] >> 4
            rx = ((q[1] & 0x0F) << 8) | q[2]
            ry = ((q[3] & 0x0F) << 8) | q[4]
        else:
            tid = q[6] >> 4
            rx = (q[4] << 4) | (q[5] & 0x0F)
            ry = (q[7] << 4) | (q[8] & 0x0F)
        if tid >= PT_MAX or (rx == 0 and ry == 0):
            continue
        if rx >= lim_x or ry >= lim_y:
            continue
        out.append((tid, rx, ry, scale(rx, PANEL_W, override_x), scale(ry, PANEL_H, override_y)))
        mask |= 1 << tid
    return out, mask


def poll(buf, override_x=0, override_y=0):
    head = buf[0]
    best = None
    for count in (head & 0x0F, (head >> 4) & 0x0F):
        if count == 0:
            continue
        count = min(count, FTS_POINTS_MAX)
        for stride in (6, 8):
            got, mask = points(buf, count, stride, override_x, override_y)
            if got and (best is None or len(got) > len(best[0])):
                best = (got, mask, stride, count)
    return best


def frame_from_hexdump(text):
    """Turn the phone's 'ff ff ff ...' dump (with a header line) into bytes."""
    data = []
    for line in text.splitlines()[1:]:
        for tok in line.split():
            if len(tok) == 2:
                data.append(int(tok, 16))
    return bytes(data)


def check(name, cond, detail=''):
    print('%-54s %s %s' % (name, 'PASS' if cond else 'FAIL', detail))
    return cond


def main():
    ok = True

    ok &= check('all 0xff frame yields no points', poll(bytes([0xFF]) * 96) is None)
    ok &= check('all 0x00 frame yields no points', poll(bytes([0x00]) * 96) is None)

    for path in sys.argv[1:]:
        try:
            raw = frame_from_hexdump(open(path, encoding='utf-8', errors='replace').read())
        except OSError as exc:
            print('  (skip %s: %s)' % (path, exc))
            continue
        if not raw:
            print('  (skip %s: no data)' % path)
            continue
        res = poll(raw)
        ok &= check('real idle frame %s (%d B)' % (path.replace('\\', '/').split('/')[-1], len(raw)),
                    res is None, '' if res is None else 'got %d points' % len(res[0]))

    # 6-byte frame: head 0x21, first record x=0x400 y=0x100
    f = bytearray(96)
    f[0] = 0x21
    f[1], f[2], f[3], f[4], f[5] = 0x00, 0x64, 0x00, 0xC8, 0x10
    res = poll(bytes(f))
    ok &= check('6-byte single point parsed', bool(res and res[0]), '' if not res else '%r' % (res[0][:1],))
    if res:
        tid, rx, ry, px, py = res[0][0]
        ok &= check('  id/x/y decode', (tid, rx, ry) == (0, 1024, 2064), '%r' % ((tid, rx, ry),))
        ok &= check('  inside the panel', 0 <= px < PANEL_W and 0 <= py < PANEL_H, '(%d, %d)' % (px, py))

    # a 0x0f-led record (all-0xff coordinates) must not become a touch
    f2 = bytearray(96)
    f2[0] = 0x01
    f2[1], f2[2], f2[3], f2[4] = 0x0F, 0xFF, 0x0F, 0xFF
    ok &= check('all-0xff record rejected', poll(bytes(f2)) is None)

    # an override rescales and widens the accepted range
    res = poll(bytes(f), override_x=2400, override_y=5216)
    ok &= check('override halves the scale',
                bool(res) and (res[0][0][3], res[0][0][4]) == (512, 1032),
                '' if not res else '(%d, %d)' % (res[0][0][3], res[0][0][4]))

    print('\n%s' % ('ALL PASS' if ok else 'SOME FAILED'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
