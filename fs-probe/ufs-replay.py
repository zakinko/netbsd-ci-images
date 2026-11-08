#!/usr/bin/env python3
# fsstress -v の記録から一つのファイルへの操作を抜き出したもの (replay/*.ops)
# を、同じ順に同じ位置と長さで一つのファイルへかけ直す。中身は fsstress と
# 違って一定の byte で書く。比べるのは umount の前後なので、中身は何でもよい。
#   ufs-replay.py <ops> <file> [skip,...]
# skip に行番号 (ops の先頭の数) を並べると、その操作を飛ばす。
# 成功した操作だけをかける。読む操作も cache に page を載せるのでかける。
# 頭の "#ino N" は記録の中のこのファイルの inode 番号で、splice、copyrange
# のどちらの側かを決める。"#image" は ufs-crash.sh が読む。
import mmap
import os
import re
import sys

ops, path = sys.argv[1], sys.argv[2]
skip = set(sys.argv[3].split(",")) if len(sys.argv) > 3 and sys.argv[3] else set()
fill = b"\x5a"
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)


def mm(off, n, flags, write):
	# fsstress は page に揃える。page の大きい機械でも動くよう、揃わない分は
	# 写像の内側でずらす。
	lead = off % mmap.ALLOCATIONGRANULARITY
	m = mmap.mmap(fd, lead + n, flags=mmap.MAP_SHARED if flags == "SHARED" else mmap.MAP_PRIVATE,
		      prot=mmap.PROT_READ | mmap.PROT_WRITE, offset=off - lead)
	if write:
		m[lead:] = fill * n
	else:
		m[lead:]
	m.close()


ino = None
for line in open(ops):
	if line.startswith("#"):
		if line.startswith("#ino "):
			ino = line.split()[1]
		continue
	no, rest = line.split(":", 1)
	if no in skip:
		continue
	rest = rest.strip()
	m = re.match(r"(write(?: dontcache)?) \S+\[[^]]*\] \[(\d+),(\d+)\] 0$", rest)
	if m:
		os.pwrite(fd, fill * int(m[3]), int(m[2]))
		print(no, m[1], m[2], m[3])
		continue
	m = re.match(r"writev \S+\[[^]]*\] \[(\d+),(\d+),(\d+)\] 0$", rest)
	if m:
		os.pwrite(fd, fill * (int(m[2]) * int(m[3])), int(m[1]))
		print(no, "writev", m[1], int(m[2]) * int(m[3]))
		continue
	m = re.match(r"(mwrite|mread) \S+\[[^]]*\] \[(\d+),(\d+),(SHARED|PRIVATE)\] 0$", rest)
	if m:
		mm(int(m[2]), int(m[3]), m[4], m[1] == "mwrite")
		print(no, m[1], m[2], m[3], m[4])
		continue
	m = re.match(r"read \S+\[[^]]*\] \[(\d+),(\d+)\] 0$", rest)
	if m:
		os.pread(fd, int(m[2]), int(m[1]))
		print(no, "read", m[1], m[2])
		continue
	# splice、copyrange の読み手ならその範囲を読み、書き手なら書く。中身は
	# 記録に無いので、書く側は一定の byte で。
	m = re.match(r"(splice|copyrange) \S+\[(\d+) [^]]*\] \[(\d+),(\d+)\] -> \S+\[(\d+) [^]]*\] \[(\d+),(\d+)\](?: 0)?$", rest)
	if m and "??" not in rest:
		if m[2] == ino:
			os.pread(fd, int(m[4]), int(m[3]))
			print(no, m[1], "read", m[3], m[4])
		elif m[5] == ino:
			os.pwrite(fd, fill * int(m[7]), int(m[6]))
			print(no, m[1], "write", m[6], m[7])
		continue
	m = re.match(r"truncate \S+\[[^]]*\] (\d+) 0$", rest)
	if m:
		os.ftruncate(fd, int(m[1]))
		print(no, "truncate", m[1])
		continue
	if re.match(r"fsync \S+ 0$", rest):
		os.fsync(fd)
		print(no, "fsync")
		continue
os.close(fd)
