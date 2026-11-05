#!/usr/bin/env python3
# dm-log-writes の記録を一件ずつ base へ足し、各時点で mount して、途中で
# 電源が落ちた場合に file から古い disk の中身が読めるかを数える。
#   ufs-crash.py <base.img> <log dev> <ufstype> <file> <bsize>
# 印は書き込みの page の中と、同じ block の残りとに分けて数える。
# 形式: Documentation/admin-guide/device-mapper/log-writes.rst
import os, struct, subprocess, sys

base, logdev, ufstype, name, bsize = sys.argv[1:6]
bsize = int(bsize)
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
	try:
		with open(os.path.join(MNT, name), "rb") as f:
			off = 0
			while True:
				b = f.read(4096)
				if not b:
					break
				if MARK in b:
					if (off & (bsize - 1)) == 8192:
						inpage += 1
					else:
						rest += 1
				off += 4096
	except OSError:
		pass
	sh("umount", MNT)
	sh("losetup", "-d", loop)
	return True, inpage, rest


log = os.open(logdev, os.O_RDONLY)
magic, ver, nr, sectorsize = struct.unpack("<QQQI", os.pread(log, 28, 0))
if magic != 0x6a736677736872 or ver != 1 or sectorsize != SS:
	sys.exit("bad log: %x %d %d" % (magic, ver, sectorsize))
img = os.open(base, os.O_WRONLY)
pos = SS
worst = [0, 0]
nowhere = hit = 0
for i in range(nr):
	sector, nsec, flags, dlen = struct.unpack("<QQQQ", os.pread(log, 32, pos))
	pos += SS
	if flags & 8:		# LOG_MARK_FLAG
		continue
	if nsec and not flags & 4:	# LOG_DISCARD_FLAG
		os.pwrite(img, os.pread(log, nsec * SS, pos), sector * SS)
		pos += nsec * SS
		m, a, b = scan()
		nowhere += not m
		hit += bool(a or b)
		if a > worst[0] or b > worst[1]:
			print("entry %d/%d sector %d: written-page %d, rest-of-block %d"
			      % (i, nr, sector, a, b))
		worst = [max(worst[0], a), max(worst[1], b)]
m, a, b = scan()
print("entries %d, unmountable points %d, points with old contents %d, "
      "worst written-page %d, worst rest-of-block %d, final %d %d"
      % (nr, nowhere, hit, worst[0], worst[1], a, b))
