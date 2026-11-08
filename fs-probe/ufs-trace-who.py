#!/usr/bin/env python3
# ufs-trace.py の trace から、ファイルのある位置の fragment の来歴を引く。
#   ufs-trace-who.py <trace> <file> <offset>
# 物理番号は FIBMAP で今の割り当てを引く (fragment 単位、fs の頭から)。
# その番号に重なる取る・移す・解放すると、そのファイルの inode の出来事を、
# trace の順に印字する。
import fcntl
import os
import re
import struct
import sys

trace, path, off = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
fsize = os.statvfs(path).f_bsize
fd = os.open(path, os.O_RDONLY)
ino = os.fstat(fd).st_ino
FIBMAP = 1
phys = struct.unpack("i", fcntl.ioctl(fd, FIBMAP, struct.pack("i", off // fsize)))[0]
os.close(fd)
print("ino %d offset %#x fsize %d phys %d" % (ino, off, fsize, phys))

ev = re.compile(r"(ufsnew|ufsmove|ufsfree) (.*)$")
for line in open(trace, errors="replace"):
	m = ev.search(line)
	if not m:
		continue
	kv = m[2].split()
	d = {kv[i]: int(kv[i + 1]) for i in range(0, len(kv) - 1, 2)}
	ranges = []
	if m[1] == "ufsnew":
		ranges.append((d["result"], d["result"] + d["new"]))
	elif m[1] == "ufsmove":
		ranges += [(d["oldb"], d["oldb"] + d["count"]), (d["newb"], d["newb"] + d["count"])]
	else:
		ranges.append((d["frag"], d["frag"] + d["count"]))
	hit = any(a <= phys < b for a, b in ranges)
	if hit or d["ino"] == ino:
		print(("* " if hit else "  ") + line.strip()[-160:])
