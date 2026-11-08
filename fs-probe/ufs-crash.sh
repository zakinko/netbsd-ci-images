#!/bin/sh
# ufs-13 の -o lazyzero は穴の残りの 0 埋めを同期書き込みから page cache へ
# 移す。既定と lazyzero で、走行中と途中の時点に古い中身が見えるかを、書き
# 込みの順序を実際に記録して確かめる。UFS_OPTS に mount option を置く。
# UFS_PARTS に行う段を並べる (既定は snap order speed stress replay)。
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
parts=${UFS_PARTS:-snap order speed stress replay}
has() { case " $parts " in *" $1 "*) ;; *) return 1 ;; esac; }
note "parts: $parts"
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
	# 直接 block と間接 block の両方に当たるよう、block ごとに同じ位置へ。
	python3 -I -c '
import os, sys
bs, off, n = map(int, sys.argv[1:4])
fd = os.open("/mnt/b/hole", os.O_WRONLY)
for i in range(0, 200):
	os.pwrite(fd, b"D" * n, i * bs + off)
if sys.argv[4] == "fsync":
	os.fsync(fd)
os.close(fd)' $bs $woff $wlen $s
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
# flusher を重ねると dm-log-writes の記録では既定の mount でも古い中身が見えるが、
# 止めて写すと既定では見えない (2026-11-06、理由は記録が無い)。順序は写しで測る。
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
			d=$(python3 -I -c '
b = open("/mnt/c/hole", "rb").read()
print(sum(b[i:i + 4096] == b"D" * 4096 for i in range(0, len(b), 4096)))')
			umount /mnt/c
		else
			c=unmountable d=0
		fi
		losetup -d $su
		rm -f $work/s.img
		note "$n snap $k old-pages $c data-pages $d"
		[ "$c" = 0 ] || [ "$c" = unmountable ] || hits=$((hits + 1))
	done
	wait $w
	sysctl -q vm.dirty_writeback_centisecs=500 vm.dirty_expire_centisecs=3000
	umount /mnt/b
	dmsetup remove lw
	losetup -d $u
	note "$n snap: $k snapshots, $hits with old contents"
}
# fsx は自分の持つ写しと読み戻しを、穴・切り詰め・mmap を含めて突き合わせ
# る。fsstress は並行に割り当てと解放を重ねる。その後 umount の前後で中身の
# hash を比べ、書き戻した後も同じかを見る。
stress() {	# image ufstype seed
	n=$1 t=$2 L=$1-s$3
	rm -f $work/u.img
	cp --sparse=always $in/$n.img $work/u.img
	u=$(losetup -f --show --direct-io=on -b 512 $work/u.img)
	mount -t ufs -o rw,ufstype=$t${UFS_OPTS:+,$UFS_OPTS} $u /mnt/b || { note "!! mount $n"; exit 1; }
	rm -rf /mnt/b/src; sync
	# fsx は種で決まるので、最初の回だけ。
	[ $3 = ${seeds%% *} ] && for seed in 1 2 3; do
		timeout 900 $fsx -q -N 30000 -S $seed -l 8388608 /mnt/b/fsx.$seed \
			> $out/$L-fsx.$seed 2>&1
		st=$?
		note "$n fsx seed $seed: exit $st"
		[ $st = 0 ] || { grep -vE '^[0-9]+\(|^ *$' $out/$L-fsx.$seed | head -12 | cut -c1-160 | sed 's/^/    /' | tee -a $sum
			echo fsx >> $out/build-failed; }
	done
	# -v は操作を一つずつ記録する。remount で中身が変わったファイルに何が
	# 起きたかを後で辿る。
	timeout 900 $fsstress -v -d /mnt/b/fss -n 4000 -p 4 -s $3 > $out/$L-fss.log 2>&1
	st=$?
	note "$L fsstress: exit $st"
	[ $st = 0 ] || echo fsstress >> $out/build-failed
	sync
	(cd /mnt/b && find . -xdev -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum) > $out/$L-tree1 2>&1
	# 違ったファイルの、umount 前に見えていた中身を後で byte 単位で比べる。
	rm -rf $work/before; mkdir -p $work/before
	(cd /mnt/b && find . -xdev -type f -print0 | cpio -0pdm --quiet $work/before) 2>/dev/null
	(cd /mnt/b && find . -xdev -printf '%i %y %s %b %p\n') > $out/$L-inodes1
	umount /mnt/b; echo 3 > /proc/sys/vm/drop_caches
	mount -t ufs -o ro,ufstype=$t $u /mnt/b || { note "!! remount $n"; exit 1; }
	(cd /mnt/b && find . -xdev -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum) > $out/$L-tree2 2>&1
	(cd /mnt/b && find . -xdev -printf '%i %y %s %b %p\n') > $out/$L-inodes2
	# 変わった byte の数、最初と最後の位置、後の側が 0 か、前の側が 0 か。
	diff $out/$L-tree1 $out/$L-tree2 | sed -n 's/^< [0-9a-f]*  //p' | while read -r f; do
		note "    $f: $(python3 -I -c '
import sys
a = open(sys.argv[1], "rb").read(); b = open(sys.argv[2], "rb").read()
d = [i for i in range(min(len(a), len(b))) if a[i] != b[i]]
if not d:
	print("sizes", len(a), len(b)); sys.exit()
print("size", len(a), "bytes", len(d), "first", hex(d[0]), "last", hex(d[-1]),
      "after-zero", sum(b[i] == 0 for i in d), "before-zero", sum(a[i] == 0 for i in d),
      "pages", sorted({i >> 12 for i in d})[:12])' "$work/before/$f" "/mnt/b/$f")"
		mkdir -p "$out/diff/$L/$(dirname "$f")"
		cp "$work/before/$f" "$out/diff/$L/$f.before"; cp "/mnt/b/$f" "$out/diff/$L/$f.after"
	done
	rm -rf $work/before
	umount /mnt/b; losetup -d $u
	d=$(diff $out/$L-tree1 $out/$L-tree2 | grep -c '^[<>]')
	note "$L after remount: differing lines $d of $(wc -l < $out/$L-tree1)"
	[ $d = 0 ] || echo remount >> $out/build-failed
	dmesg -c > $out/$L-stress.dmesg
	grep -iE 'ufs|bug|warn' $out/$L-stress.dmesg | head -8 | sed 's/^/    dmesg: /' | tee -a $sum
	rm -f $work/u.img
}
# fsstress の後で umount の前後に中身が変わったファイルの操作を、replay/ に
# 抜き出してある。印で埋めた空き領域の上でかけ直し、変わるかを見る。変わる
# なら、操作を一つずつ外して、どれが要るかを数える。
replay_once() {	# ops skip
	cp --sparse=always $work/rbase.img $work/u.img
	u=$(losetup -f --show --direct-io=on -b 512 $work/u.img)
	mount -t ufs -o rw,ufstype=ufs2${UFS_OPTS:+,$UFS_OPTS} $u /mnt/b || { note "!! mount replay"; exit 1; }
	python3 -I $here/ufs-replay.py $1 /mnt/b/r "$2" > $work/replay.out
	python3 -I -c '
import sys
open(sys.argv[2], "wb").write(open(sys.argv[1], "rb").read())' /mnt/b/r $work/r.before
	umount /mnt/b; echo 3 > /proc/sys/vm/drop_caches
	mount -t ufs -o ro,ufstype=ufs2 $u /mnt/b || { note "!! remount replay"; exit 1; }
	rr=$(python3 -I -c '
import sys
a = open(sys.argv[1], "rb").read(); b = open(sys.argv[2], "rb").read()
d = [i for i in range(min(len(a), len(b))) if a[i] != b[i]]
print(len(d), hex(d[0]) if d else "-", hex(d[-1]) if d else "-",
      sum(b"SENTINEL" in b[i:i + 4096] for i in range(0, len(b), 4096)))' $work/r.before /mnt/b/r)
	umount /mnt/b; losetup -d $u
	rm -f $work/u.img $work/r.before
}
replay() {	# image ops
	prepare $1 ufs2 1M
	mv $work/u.img $work/rbase.img
	o=$here/replay/$2.ops
	replay_once $o ""
	note "$1 replay $2: differing-bytes first last sentinel-pages $rr"
	if [ "${rr%% *}" != 0 ]; then
		echo replay-$2 >> $out/build-failed
		cp $work/replay.out $out/replay-$2.ops-done
		for k in $(cut -d" " -f1 $out/replay-$2.ops-done); do
			replay_once $o $k
			note "    without $(grep "^$k " $out/replay-$2.ops-done): $rr"
		done
	fi
	rm -f $work/rbase.img
}
if has replay; then
	for o in $here/replay/*.ops; do
		replay netbsd-ffs2 $(basename $o .ops)
	done
fi
if has stress; then
	dnf -y -q install git autoconf automake libtool libuuid-devel xfsprogs-devel \
		libaio-devel libacl-devel libattr-devel
	# stress.sh と同じ版の xfstests の ltp/ から建てる。
	xfstests_tag=v2026.10.15
	git clone -q --depth 1 --branch $xfstests_tag \
		https://git.kernel.org/pub/scm/fs/xfs/xfstests-dev.git $work/xfstests
	note "xfstests: $(git -C $work/xfstests log -1 --format='%h %cd' --date=short)"
	(cd $work/xfstests && make configure > $out/xfstests-build.log 2>&1 &&
		./configure >> $out/xfstests-build.log 2>&1 &&
		make -C lib >> $out/xfstests-build.log 2>&1 &&
		make -C ltp fsx fsstress >> $out/xfstests-build.log 2>&1)
	fsx=$work/xfstests/ltp/fsx
	fsstress=$work/xfstests/ltp/fsstress
	if [ ! -x $fsx ] || [ ! -x $fsstress ]; then
		note "!! fsx/fsstress did not build"
		tail -20 $out/xfstests-build.log | tee -a $sum
		exit 1
	fi
	dmesg -c > /dev/null
	# fsx が ufs で止まったとき、同じ版の kernel の別の fs でも止まるかで
	# ufs のせいかを分ける。root fs (xfs) で同じ種を回す。
	for seed in 1 2 3; do
		timeout 900 $fsx -q -N 30000 -S $seed -l 8388608 $work/fsx.$seed > $out/rootfs-fsx.$seed 2>&1
		note "root fs ($(findmnt -no FSTYPE -T $work)) fsx seed $seed: exit $?"
		rm -f $work/fsx.$seed*
	done
	# 並行の負荷でしか出ないものを数えるため、種を変えて新しい image で繰り返す。
	seeds=${UFS_STRESS_SEEDS:-1}
	for n in netbsd-ffs2 freebsd-ufs2; do
		for k in $seeds; do
			stress $n ufs2 $k
		done
	done
fi
has snap && for n in netbsd-ffs2 freebsd-ufs2; do
	snap $n ufs2
done
has order && for n in netbsd-ffs2 freebsd-ufs2; do
	for s in sync fsync background; do
		scenario $n ufs2 $s 8192 4096
		scenario $n ufs2 $s 1000 100
		scenario $n ufs2 $s 2048 4096
	done
done
has speed && for n in netbsd-ffs2 freebsd-ufs2; do
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
