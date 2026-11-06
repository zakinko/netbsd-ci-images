#!/bin/sh
# ufs-13 の -o lazyzero は穴の残りの 0 埋めを同期書き込みから page cache へ
# 移す。既定と lazyzero で、走行中と途中の時点に古い中身が見えるかを、書き
# 込みの順序を実際に記録して確かめる。UFS_OPTS に mount option を置く。
#   ufs-crash.sh <indir> <outdir>
# 空き領域を全部印で埋めて消してから、穴に書く。
set -u
in=$(cd "$1" && pwd)
mkdir -p "$2"
out=$(cd "$2" && pwd)
work=/var/tmp/fsc
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p $work /mnt/b /mnt/c
sum=$out/crash.txt
: > $sum
note() { printf '%s\n' "$*" | tee -a $sum; }
note "# ufs-crash / kernel $(uname -r) FS_PATCH=${FS_PATCH:-0} OMIT=${FS_PATCH_OMIT:-}"
dnf -y -q install epel-release
dnf -y -q install fio patch gcc make elfutils-libelf-devel rpm cpio xz tar bc \
	kernel-headers device-mapper
# kernel-ml は kernel-ml-modules-extra を kernel.sh が入れている。
case $(uname -r) in
*elrepo*) ;;
*)	dnf -y -q install kernel-modules-extra-$(uname -r) ||
	dnf -y -q install https://vault.almalinux.org/$(uname -r | sed -n 's/.*\.el10_\([0-9]*\)\..*/10.\1/p')/BaseOS/x86_64/os/Packages/kernel-modules-extra-$(uname -r).rpm ;;
esac
modprobe dm-log-writes || { note "!! no dm-log-writes"; exit 1; }
. $here/ksrc.sh
fs_build ufs $out/ufs-build.log
note "ufs build+insmod exit $?"

# 空き領域を印で埋めて消し、穴を作る。bs に block の大きさを返す。
prepare() {	# image ufstype holesize
	n=$1 t=$2
	rm -f $work/*.img $work/log.raw
	cp --sparse=always $in/$n.img $work/u.img
	u=$(losetup -f --show --direct-io=on -b 512 $work/u.img)
	mount -t ufs -o rw,ufstype=$t $u /mnt/b || { note "!! mount $n"; exit 1; }
	rm -rf /mnt/b/src
	python3 -I -c '
b = b"SENTINEL" * 131072
try:
	with open("/mnt/b/fill", "wb", 0) as f:
		while True:
			f.write(b)
except OSError:
	pass'
	sync; rm -f /mnt/b/fill; sync
	# statvfs の f_bsize は fragment なので、superblock の fs_bsize を読む。
	bs=$(python3 -I -c '
import struct, sys
print(struct.unpack("<i", open(sys.argv[1], "rb").read(65536 + 52)[65536 + 48:])[0])' $u)
	truncate -s $3 /mnt/b/hole
	sync; umount /mnt/b; losetup -d $u
}

scenario() {	# image ufstype scenario off len
	s=$3 woff=$4 wlen=$5
	prepare $1 $2 16M
	cp --sparse=never $work/u.img $work/base.img
	truncate -s 4G $work/log.raw
	u=$(losetup -f --show --direct-io=on -b 512 $work/u.img)
	l=$(losetup -f --show --direct-io=on -b 512 $work/log.raw)
	dmsetup create lw --table "0 $(blockdev --getsz $u) log-writes $u $l"
	mount -t ufs -o rw,ufstype=$t${UFS_OPTS:+,$UFS_OPTS} /dev/mapper/lw /mnt/b || { note "!! mount lw"; exit 1; }
	# race は flusher を書き込みに重ねる。fsync の途中で一度だけ順序が崩れた
	# ことがあり (6.12、4 回に 1 回)、待っていては再現しない。
	if [ $s = race ]; then
		sysctl -q vm.dirty_writeback_centisecs=1 vm.dirty_expire_centisecs=1
	fi
	# 直接 block と間接 block の両方に当たるよう、block ごとに同じ位置へ。
	python3 -I -c '
import os, sys
bs, off, n = map(int, sys.argv[1:4])
fd = os.open("/mnt/b/hole", os.O_WRONLY)
for i in range(0, 200):
	os.pwrite(fd, b"D" * n, i * bs + off)
if sys.argv[4] in ("fsync", "race"):
	os.fsync(fd)
os.close(fd)' $bs $woff $wlen $s
	if [ $s = race ]; then
		sysctl -q vm.dirty_writeback_centisecs=500 vm.dirty_expire_centisecs=3000
	fi
	live=$(grep -c SENTINEL /mnt/b/hole)
	echo 3 > /proc/sys/vm/drop_caches
	cold=$(python3 -I -c '
b = open("/mnt/b/hole", "rb").read()
print(sum(b"SENTINEL" in b[i:i + 4096] for i in range(0, len(b), 4096)))')
	if [ $s = background ]; then
		sysctl -q vm.dirty_writeback_centisecs=20 vm.dirty_expire_centisecs=50
		sleep 8
		sysctl -q vm.dirty_writeback_centisecs=500 vm.dirty_expire_centisecs=3000
	fi
	sync; umount /mnt/b
	dmsetup remove lw
	losetup -d $u
	note "$n $s off $woff len $wlen bsize $bs live-lines $live cold-pages $cold: $(python3 -I $here/ufs-crash.py $work/base.img $l $t hole $bs $woff $wlen | tee -a $out/$n-$s-$woff.log | tail -1)"
	losetup -d $l
}
# dm-log-writes を通さずに測る。書き込みの途中で device を止めて写すので、写し
# に在るのは止めた時点までに完了した書き込みそのもので、記録の順序によらない。
snap() {	# image ufstype
	prepare $1 $2 128M
	u=$(losetup -f --show --direct-io=on -b 512 $work/u.img)
	dmsetup create lw --table "0 $(blockdev --getsz $u) linear $u 0"
	mount -t ufs -o rw,ufstype=$t${UFS_OPTS:+,$UFS_OPTS} /dev/mapper/lw /mnt/b || { note "!! mount lw"; exit 1; }
	sysctl -q vm.dirty_writeback_centisecs=1 vm.dirty_expire_centisecs=1
	python3 -I -c '
import os, sys, time
bs = int(sys.argv[1])
fd = os.open("/mnt/b/hole", os.O_WRONLY)
for i in range(0, 4000):
	os.pwrite(fd, b"D" * 4096, i * bs + 8192)
	time.sleep(0.001)
os.fsync(fd)
os.close(fd)' $bs &
	w=$!
	k=0 hits=0
	while [ $k -lt 12 ] && kill -0 $w 2>/dev/null; do
		k=$((k + 1))
		sleep 0.2
		dmsetup suspend --nolockfs lw
		cp --sparse=always $work/u.img $work/s.img
		dmsetup resume lw
		su=$(losetup -f --show -r -b 512 $work/s.img)
		if mount -t ufs -o ro,ufstype=$t $su /mnt/c; then
			c=$(python3 -I -c '
b = open("/mnt/c/hole", "rb").read()
print(sum(b"SENTINEL" in b[i:i + 4096] for i in range(0, len(b), 4096)))')
			umount /mnt/c
		else
			c=unmountable
		fi
		losetup -d $su
		rm -f $work/s.img
		note "$n snap $k old-pages $c"
		[ "$c" = 0 ] || [ "$c" = unmountable ] || hits=$((hits + 1))
	done
	wait $w
	sysctl -q vm.dirty_writeback_centisecs=500 vm.dirty_expire_centisecs=3000
	umount /mnt/b
	dmsetup remove lw
	losetup -d $u
	note "$n snap: $k snapshots, $hits with old contents"
}
for n in netbsd-ffs2 freebsd-ufs2; do
	snap $n ufs2
done
[ -n "${UFS_SNAP_ONLY:-}" ] && exit 0
for n in netbsd-ffs2 freebsd-ufs2; do
	for s in sync fsync background; do
		scenario $n ufs2 $s 8192 4096
		scenario $n ufs2 $s 1000 100
		scenario $n ufs2 $s 2048 4096
	done
done
for n in netbsd-ffs2 freebsd-ufs2; do
	for i in 1 2 3 4 5 6; do
		scenario $n ufs2 race 8192 4096
	done
done
for n in netbsd-ffs2 freebsd-ufs2; do
	rm -f $work/u.img
	cp --sparse=always $in/$n.img $work/u.img
	u=$(losetup -f --show --direct-io=on -b 512 $work/u.img)
	mount -t ufs -o rw,ufstype=ufs2${UFS_OPTS:+,$UFS_OPTS} $u /mnt/b
	note "$(findmnt -no OPTIONS /mnt/b)"
	rm -rf /mnt/b/src; sync
	for i in 1 2 3; do
		fio --name=rw --directory=/mnt/b --rw=randwrite --bs=4k --size=64M \
		    --end_fsync=1 --output-format=json > $work/rw.json
		note "$n rand4k $(python3 -I -c 'import json,sys;print(round(json.load(open(sys.argv[1]))["jobs"][0]["write"]["iops"]))' $work/rw.json)"
		rm -f /mnt/b/rw.*; sync; echo 3 > /proc/sys/vm/drop_caches
	done
	# 穴を埋めた直後に切り詰める。解放した間接 block を保留のまま書き戻すと、
	# そこを再利用した次の file が壊れる。
	python3 -I -c '
import hashlib, os
fd = os.open("/mnt/b/t1", os.O_CREAT | os.O_WRONLY, 0o644)
os.ftruncate(fd, 64 << 20)
for i in range(0, 64 << 20, 1 << 16):
	os.pwrite(fd, b"D" * 4096, i)
os.ftruncate(fd, 4096)
os.close(fd)
fd = os.open("/mnt/b/t2", os.O_CREAT | os.O_WRONLY, 0o644)
h = hashlib.sha256()
for i in range(1024):
	b = bytes([i & 255]) * 65536
	h.update(b)
	os.write(fd, b)
os.close(fd)
print(h.hexdigest())' > $work/t2.want
	sync; umount /mnt/b; echo 3 > /proc/sys/vm/drop_caches
	mount -t ufs -o rw,ufstype=ufs2${UFS_OPTS:+,$UFS_OPTS} $u /mnt/b
	if [ "$(sha256sum < /mnt/b/t2 | cut -d" " -f1)" = "$(cat $work/t2.want)" ]; then
		note "$n truncate-reuse ok"
	else
		note "!! $n truncate-reuse corrupted"
		echo truncate-reuse >> $out/build-failed
	fi
	rm -f /mnt/b/t1 /mnt/b/t2
	umount /mnt/b; losetup -d $u
done
rm -f $work/*.img $work/log.raw
if [ -s $out/build-failed ]; then
	note "!! not built: $(tr '\n' ' ' < $out/build-failed)"
	exit 1
fi
