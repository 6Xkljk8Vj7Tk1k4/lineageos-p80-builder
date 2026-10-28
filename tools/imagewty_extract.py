#!/usr/bin/env python3
"""List or extract the items of an unencrypted Allwinner IMAGEWTY (PhoenixSuit) image.

Usage:
  python3 -I imagewty_extract.py Firmware.img            # list items
  python3 -I imagewty_extract.py Firmware.img OUTDIR     # extract all items to OUTDIR

Layout (header version 0x300): 1024-byte image header (item count at offset 60),
then one 1024-byte header per item: filename at 36 (256 bytes), stored length at 292,
original length at 300, data offset at 308. Streams the data, so it works on
multi-GB images without loading them into memory.
"""
import os
import struct
import sys


def main():
    img = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else None
    with open(img, "rb") as f:
        hdr = f.read(1024)
        if hdr[:8] != b"IMAGEWTY":
            sys.exit("not an unencrypted IMAGEWTY image")
        hver, = struct.unpack("<I", hdr[8:12])
        if hver != 0x300:
            sys.exit("unsupported header version %#x" % hver)
        n, = struct.unpack("<I", hdr[60:64])
        items = []
        for i in range(n):
            h = f.read(1024)
            name = h[36:292].split(b"\0")[0].decode("latin1")
            _stored, _, orig, _, off = struct.unpack("<5I", h[292:312])
            items.append((name, orig, off))
        for name, size, off in items:
            print("%-28s %12d bytes at %#x" % (name, size, off))
        if not out:
            return
        os.makedirs(out, exist_ok=True)
        for name, size, off in items:
            dst = os.path.join(out, os.path.basename(name))
            f.seek(off)
            left = size
            with open(dst, "wb") as o:
                while left:
                    chunk = f.read(min(left, 16 << 20))
                    if not chunk:
                        sys.exit("truncated image at %s" % name)
                    o.write(chunk)
                    left -= len(chunk)


if __name__ == "__main__":
    main()
