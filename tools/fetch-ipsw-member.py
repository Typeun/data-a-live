#!/usr/bin/env python3
"""Fetch one member of a remote IPSW (zip64) with HTTP range requests.

Usage: fetch-ipsw-member.py URL MEMBER [OUT]
"""
import struct
import sys
import urllib.request
import zlib


class Remote:
    def __init__(self, url):
        self.url = url
        req = urllib.request.Request(url, method='HEAD')
        with urllib.request.urlopen(req, timeout=60) as r:
            self.size = int(r.headers['Content-Length'])

    def read(self, start, length):
        req = urllib.request.Request(self.url, headers={'Range': 'bytes=%d-%d' % (start, start + length - 1)})
        with urllib.request.urlopen(req, timeout=180) as r:
            data = r.read()
        if len(data) != length:
            raise SystemExit('short read %d/%d at %d' % (len(data), length, start))
        return data


def u64(buf, at):
    return struct.unpack_from('<Q', buf, at)[0]


def zip64_extra(extra):
    """Return (usize, csize, local) from the 0x0001 extra field."""
    at = 0
    while at + 4 <= len(extra):
        tag, size = struct.unpack_from('<HH', extra, at)
        body = extra[at + 4:at + 4 + size]
        if tag == 0x0001:
            values, pos = [], 0
            while pos + 8 <= len(body):
                values.append(u64(body, pos))
                pos += 8
            return values
        at += 4 + size
    return []


def central_directory(source):
    tail_len = min(source.size, 256 * 1024)
    tail = source.read(source.size - tail_len, tail_len)
    eocd = tail.rfind(b'PK\x05\x06')
    if eocd < 0:
        raise SystemExit('no EOCD')
    count = struct.unpack_from('<H', tail, eocd + 10)[0]
    cd_size, cd_off = struct.unpack_from('<II', tail, eocd + 12)
    if cd_off == 0xFFFFFFFF or cd_size == 0xFFFFFFFF:
        loc = tail.rfind(b'PK\x06\x07', 0, eocd)
        if loc < 0:
            raise SystemExit('no zip64 locator')
        z64_off = u64(tail, loc + 8)
        rec = source.read(z64_off, 56)
        if rec[:4] != b'PK\x06\x06':
            raise SystemExit('bad zip64 EOCD')
        count = u64(rec, 32)
        cd_size, cd_off = u64(rec, 40), u64(rec, 48)
    return count, source.read(cd_off, cd_size)


def find(cd, count, name):
    pos = 0
    for _ in range(count):
        if cd[pos:pos + 4] != b'PK\x01\x02':
            raise SystemExit('bad central directory entry')
        method = struct.unpack_from('<H', cd, pos + 10)[0]
        csize, usize = struct.unpack_from('<II', cd, pos + 20)
        nlen, elen, clen = struct.unpack_from('<HHH', cd, pos + 28)
        local = struct.unpack_from('<I', cd, pos + 42)[0]
        entry = cd[pos + 46:pos + 46 + nlen].decode('utf-8', 'replace')
        extra = cd[pos + 46 + nlen:pos + 46 + nlen + elen]
        if entry == name:
            if 0xFFFFFFFF in (csize, usize, local):
                values = zip64_extra(extra)
                it = iter(values)
                if usize == 0xFFFFFFFF:
                    usize = next(it)
                if csize == 0xFFFFFFFF:
                    csize = next(it)
                if local == 0xFFFFFFFF:
                    local = next(it)
            return method, csize, usize, local
        pos += 46 + nlen + elen + clen
    raise SystemExit('member not found: %s' % name)


def main():
    url, member = sys.argv[1], sys.argv[2]
    out = sys.argv[3] if len(sys.argv) > 3 else member.split('/')[-1]
    source = Remote(url)
    print('remote %d bytes' % source.size)
    count, cd = central_directory(source)
    print('zip members: %d, central directory %d bytes' % (count, len(cd)))
    method, csize, usize, local = find(cd, count, member)
    header = source.read(local, 30)
    hnlen, helen = struct.unpack_from('<HH', header, 26)
    at = local + 30 + hnlen + helen
    print('%s: method %d, %d -> %d bytes at %d' % (member, method, csize, usize, at))
    raw = source.read(at, csize)
    data = raw if method == 0 else zlib.decompress(raw, -15)
    if len(data) != usize:
        raise SystemExit('size mismatch %d != %d' % (len(data), usize))
    open(out, 'wb').write(data)
    print('wrote %s (%d bytes)' % (out, len(data)))


if __name__ == '__main__':
    main()
