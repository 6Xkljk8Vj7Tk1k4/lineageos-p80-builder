#!/usr/bin/env python3
"""Rename the block device in an LP metadata image file and fix its checksums.

gsid (Android 11+) records the DSU backing device by its kernel name (mmcblk0p17 on the P80), the
Android 10 first-stage init only finds it by its GPT name (UDISK). The file is the format gsid
writes to /metadata/gsi/dsu/<slot>/lp_metadata: a 4096-byte geometry block, then one metadata
header and its tables, each covered by a SHA-256 checksum.

Usage: lp_metadata_rename.py FILE                 list partitions and block devices
       lp_metadata_rename.py FILE OLD NEW OUTFILE  write a copy with block device OLD renamed
"""
import hashlib
import struct
import sys

GEOMETRY_SIZE = 4096
HEADER_MAGIC = 0x414C5030


def main():
    data = bytearray(open(sys.argv[1], "rb").read())
    h = GEOMETRY_SIZE
    magic, major, minor, header_size = struct.unpack_from("<IHHI", data, h)
    if magic != HEADER_MAGIC:
        sys.exit("no LP metadata header at %d" % h)
    tables_size = struct.unpack_from("<I", data, h + 44)[0]
    # table descriptors: partitions, extents, groups, block devices (offset, count, entry size)
    descs = [struct.unpack_from("<III", data, h + 80 + 12 * i) for i in range(4)]
    tables = h + header_size
    print("LP metadata %d.%d" % (major, minor))
    t_off, num, size = descs[0]
    for i in range(num):
        e = tables + t_off + i * size
        print("  partition", data[e:e + 36].split(b"\0")[0].decode())
    t_off, num, size = descs[3]
    devices = [tables + t_off + i * size + 24 for i in range(num)]  # name after 24 bytes of sizes
    for e in devices:
        print("  block device", data[e:e + 36].split(b"\0")[0].decode())
    if len(sys.argv) != 5:
        return

    old, new = sys.argv[2].encode(), sys.argv[3].encode()
    renamed = [e for e in devices if data[e:e + 36].split(b"\0")[0] == old]
    if not renamed or len(new) >= 36:
        sys.exit("block device %s not found or new name too long" % sys.argv[2])
    for e in renamed:
        data[e:e + 36] = new.ljust(36, b"\0")
    # tables checksum (inside the header) first, then the header checksum over a zeroed field
    data[h + 48:h + 80] = hashlib.sha256(bytes(data[tables:tables + tables_size])).digest()
    data[h + 12:h + 44] = bytes(32)
    data[h + 12:h + 44] = hashlib.sha256(bytes(data[h:h + header_size])).digest()
    open(sys.argv[4], "wb").write(data)
    print("renamed %s to %s in %s" % (sys.argv[2], sys.argv[3], sys.argv[4]))


if __name__ == "__main__":
    main()
