#!/usr/bin/env python3
# NetBSD の quota2 ファイルの header を image の中から探し、欄を書き換える。
#   q2poke.py image type sum            header と hash 表の sha256 を出す
#   q2poke.py image type field=value…   欄を書き換える
# type は 0 (user) か 1 (group)。header の形は NetBSD の
# sys/ufs/ufs/quota2.h (struct quota2_header) による。fs/ufs/quota2.h の
# static_assert と同じく、q2h_free は 104、q2h_entries は 112 に在る。
# 欄の名前: shift (q2h_hash_shift, u8), size (q2h_hash_size, u16),
# free (q2h_free, u64), head0 (q2h_entries[0], u64)。
# quota ファイルは fragment の頭から始まるので、1024 byte ごとに magic を
# 見る。Linux 側の検査を通る header だけを数え、一つでなければ止まる。
import hashlib
import mmap
import struct
import sys

MAGIC = struct.pack('<I', 0xb746915e)
FIELDS = {'shift': (5, '<B'), 'size': (6, '<H'),
          'free': (104, '<Q'), 'head0': (112, '<Q')}


def find(m, qtype):
    hits = []
    i = m.find(MAGIC)
    while i >= 0:
        if i % 1024 == 0:
            typ, shift, size = struct.unpack_from('<BBH', m, i + 4)
            if typ == qtype and shift <= 15 and size == 1 << shift:
                hits.append(i)
        i = m.find(MAGIC, i + 1)
    if len(hits) != 1:
        sys.exit('quota2 header of type %d: %d candidates' % (qtype, len(hits)))
    return hits[0]


def main():
    path, qtype = sys.argv[1], int(sys.argv[2])
    with open(path, 'r+b') as f:
        m = mmap.mmap(f.fileno(), 0)
        h = find(m, qtype)
        shift = m[h + 5]
        end = h + 112 + (8 << shift)
        if sys.argv[3:] == ['sum']:
            print('header at %d, shift %d, sha256 %s' % (
                h, shift, hashlib.sha256(m[h:end]).hexdigest()[:16]))
            return
        for a in sys.argv[3:]:
            name, val = a.split('=')
            off, fmt = FIELDS[name]
            struct.pack_into(fmt, m, h + off, int(val, 0))
        m.flush()


main()
