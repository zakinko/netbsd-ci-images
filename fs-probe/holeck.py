#!/usr/bin/python3 -I
# 穴に小さく書いた後で、同じ block の書かなかった所が 0 に読めるか。
#   holeck.py write|check <file>
# ufs-13 は穴の残りを同期で zero にしなくなるので、drop_caches の後に
# ディスクの古い中身が見えたら直しの誤り。
import os, sys
PS = 4096
N = 4096
def pat(i):
    return (b'%08d' % i) * (PS // 8)
fd = os.open(sys.argv[2], os.O_RDWR | os.O_CREAT, 0o644)
want = {i * 37 % N: pat(i) for i in range(N // 8)}
if sys.argv[1] == 'write':
    os.ftruncate(fd, N * PS)
    for p, d in want.items():
        os.pwrite(fd, d, p * PS)
else:
    bad = 0
    for p in range(N):
        d = os.pread(fd, PS, p * PS)
        if d != want.get(p, bytes(PS)):
            bad += 1
    print('pages wrong: %d of %d' % (bad, N))
    sys.exit(bad != 0)
