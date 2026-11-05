#!/bin/sh
# ufs-13 は穴の残りの 0 埋めを同期書き込みから page cache へ移した。割り
# 当てより先に 0 が disk に届く保証が消えたかを、書き込みの順序を実際に
# 記録して確かめる。
#   ufs-crash.sh <indir> <outdir>
# 空き領域を全部印で埋めて消してから、穴に 4K ずつ書く。FS_PATCH_OMIT で
# ufs-13 を抜いた物と比べる。
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
dnf -y -q install patch gcc make elfutils-libelf-devel rpm cpio xz tar bc \
	device-mapper kernel-modules-extra-$(uname -r) ||
	dnf -y -q install https://vault.almalinux.org/$(uname -r | sed -n 's/.*\.el10_\([0-9]*\)\..*/10.\1/p')/BaseOS/x86_64/os/Packages/kernel-modules-extra-$(uname -r).rpm
modprobe dm-log-writes || { note "!! no dm-log-writes"; exit 1; }
. $here/ksrc.sh
fs_build ufs $out/ufs-build.log
note "ufs build+insmod exit $?"

scenario() {	# image ufstype scenario
	n=$1 t=$2 s=$3
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
	bs=$(python3 -I -c 'import os; print(os.statvfs("/mnt/b").f_bsize)')
	truncate -s 16M /mnt/b/hole
	sync; umount /mnt/b; losetup -d $u
	cp --sparse=never $work/u.img $work/base.img
	truncate -s 4G $work/log.raw
	u=$(losetup -f --show --direct-io=on -b 512 $work/u.img)
	l=$(losetup -f --show --direct-io=on -b 512 $work/log.raw)
	dmsetup create lw --table "0 $(blockdev --getsz $u) log-writes $u $l"
	mount -t ufs -o rw,ufstype=$t /dev/mapper/lw /mnt/b || { note "!! mount lw"; exit 1; }
	# 直接 block と間接 block の両方に当たるよう、block ごとに 8K の所へ。
	python3 -I -c '
import os, sys
bs = int(sys.argv[1])
fd = os.open("/mnt/b/hole", os.O_WRONLY)
for i in range(0, 200):
	os.pwrite(fd, b"D" * 4096, i * bs + 8192)
if sys.argv[2] == "fsync":
	os.fsync(fd)
os.close(fd)' $bs $s
	if [ $s = background ]; then
		sysctl -q vm.dirty_writeback_centisecs=20 vm.dirty_expire_centisecs=50
		sleep 8
		sysctl -q vm.dirty_writeback_centisecs=500 vm.dirty_expire_centisecs=3000
	fi
	sync; umount /mnt/b
	dmsetup remove lw
	losetup -d $u
	note "$n $s bsize $bs: $(python3 -I $here/ufs-crash.py $work/base.img $l $t hole $bs | tee -a $out/$n-$s.log | tail -1)"
	losetup -d $l
}
for n in netbsd-ffs2 freebsd-ufs2; do
	for s in sync fsync background; do
		scenario $n ufs2 $s
	done
done
rm -f $work/*.img $work/log.raw
if [ -s $out/build-failed ]; then
	note "!! not built: $(tr '\n' ' ' < $out/build-failed)"
	exit 1
fi
