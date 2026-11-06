#!/usr/bin/env python3
# dm-log-writes の記録を一件ずつ base へ足し、各時点で mount して、途中で
# 電源が落ちた場合に file から古い disk の中身が読めるかを数える。
#   ufs-crash.py <base.img> <log dev> <ufstype> <file> <bsize> <off> <len>
# block ごとに off から len byte 書いた file を見る。印は書き込みが触れた
# page の中と、同じ block の残りとに分けて数える。
# 形式: Documentation/admin-guide/device-mapper/log-writes.rst
import os, struct, subprocess, sys

base, logdev, ufstype, name, bsize, woff, wlen = sys.argv[1:8]
bsize, woff, wlen = int(bsize), int(woff), int(wlen)
MNT = "/mnt/c"
MARK = b"SENTINEL"
SS = 512


def sh(*a):
	return subprocess.run(a, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
			      text=True)


def scan():
	"""(mounted, 書いた page の中の印の page 数, block の残りの印の page 数)"""
	loop = sh("losetup", "-f", "--show", "-r", "-b", "512", base).stdout.strip()
	r = sh("mount", "-t", "ufs", "-o", "ro,ufstype=" + ufstype, loop, MNT)
	if r.returncode:
		sh("losetup", "-d", loop)
		return False, 0, 0
	inpage = rest = 0
	where.clear()
	try:
		with open(os.path.join(MNT, name), "rb") as f:
			off = 0
			while True:
				b = f.read(4096)
				if not b:
					break
				if MARK in b:
					o = off & (bsize - 1)
					if o < woff + wlen and woff < o + 4096:
						inpage += 1
					else:
						rest += 1
					where.append(off)
				off += 4096
	except OSError:
		pass
	sh("umount", MNT)
	sh("losetup", "-d", loop)
	return True, inpage, rest


where = []
log = os.open(logdev, os.O_RDONLY)
magic, ver, nr, sectorsize = struct.unpack("<QQQI", os.pread(log, 28, 0))
if magic != 0x6a736677736872 or ver != 1 or sectorsize != SS:
	sys.exit("bad log: %x %d %d" % (magic, ver, sectorsize))
img = os.open(base, os.O_WRONLY)
pos = SS
worst = [0, 0]
trail, first = [], []	# 最初に古い中身が見えた所までの記録の並び
nowhere = hit = 0
for i in range(nr):
	sector, nsec, flags, dlen = struct.unpack("<QQQQ", os.pread(log, 32, pos))
	pos += SS
	if flags & 8:		# LOG_MARK_FLAG
		continue
	if not nsec or flags & 4:
		trail.append("%d s=%d n=%d f=%x -" % (i, sector, nsec, flags))
	if nsec and not flags & 4:	# LOG_DISCARD_FLAG
		d = os.pread(log, nsec * SS, pos)
		os.pwrite(img, d, sector * SS)
		trail.append("%d s=%d n=%d f=%x %s" % (i, sector, nsec, flags,
			"zero" if not d.strip(b"\0") else "mark" if MARK in d else "data"))
		pos += nsec * SS
		m, a, b = scan()
		nowhere += not m
		hit += bool(a or b)
		if (a or b) and not first:
			first = [len(trail), list(where[:12])]
		if a > worst[0] or b > worst[1]:
			print("entry %d/%d sector %d: written-page %d, rest-of-block %d"
			      % (i, nr, sector, a, b))
		worst = [max(worst[0], a), max(worst[1], b)]
if first:
	print("first exposed at trail index %d: %s" % tuple(first))
	print("\n".join(trail))
m, a, b = scan()
print("entries %d, unmountable points %d, points with old contents %d, "
      "worst written-page %d, worst rest-of-block %d, final %d %d %s"
      % (nr, nowhere, hit, worst[0], worst[1], a, b, where[:8]))
