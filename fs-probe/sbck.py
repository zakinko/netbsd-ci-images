#!/usr/bin/env python3
# FreeBSD の superblock の check-hash を外から計算し直す。
# 使い方: sbck.py 書いた後の image [元の image]
# 元の image を渡すと、superblock のうち変わった byte の位置も並べる。
# 位置は FreeBSD の sys/ufs/ffs/fs.h による: SBLOCK_UFS2 65536,
# SBLOCK_UFS1 8192, fs_sbsize 104, fs_magic 1372, fs_ckhash 1304,
# fs_flags 1312 (最後の二つは fs/ufs/ufs_fs.h の offsetof でも同じ)。
import struct
import sys

T = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ (0x82F63B78 if c & 1 else 0)
    T.append(c)


def crc32c(crc, b):
    for x in b:
        crc = T[(crc ^ x) & 0xff] ^ (crc >> 8)
    return crc


def sb(path):
    with open(path, 'rb') as f:
        for off in (65536, 8192):
            f.seek(off)
            b = f.read(8192)
            magic = struct.unpack_from('<I', b, 1372)[0]
            if magic in (0x19540119, 0x011954):
                n = struct.unpack_from('<i', b, 104)[0]
                return off, b[:n]
    sys.exit('%s: no superblock' % path)


off, b = sb(sys.argv[1])
stored, flags = struct.unpack_from('<II', b, 1304)
calc = crc32c(0xffffffff, b[:1304] + b'\0' * 4 + b[1308:])
print('sb at %d size %d flags 0x%x ckhash stored 0x%08x computed 0x%08x %s'
      % (off, len(b), flags, stored, calc,
         'ok' if stored == calc else 'MISMATCH'))
if len(sys.argv) > 2:
    _, o = sb(sys.argv[2])
    d = [i for i in range(min(len(b), len(o))) if b[i] != o[i]]
    runs = []
    for i in d:
        if runs and i == runs[-1][1] + 1:
            runs[-1][1] = i
        else:
            runs.append([i, i])
    print('changed bytes: ' + ' '.join('%d-%d' % (a, z) for a, z in runs))
