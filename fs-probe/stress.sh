#!/bin/sh
# NTFS のドライバそれぞれに、xfstests の fsx と fsstress を同じ条件でかける。
#   stress.sh <outdir>
# alma.sh は決まった木を一度書くだけで、別の実装の穴を探すには足りない。
# fsx は自分の持つ写しと読み戻しを突き合わせるので、化けたらその場で
# 止まる。fsstress には答が無いので、後で remount の前後の中身、
# ntfsfix -n、dmesg、Windows の chkdsk (win-check.ps1) で確かめる。
# 出来たイメージは stress-<drv>.vhd として outdir に置く。
set -u
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$1"
out=$(cd "$1" && pwd)
work=/var/tmp/fsp
mkdir -p $work /mnt/p
sum=$out/summary.txt
: > $sum
note() { printf '%s\n' "$*" | tee -a $sum; }
KV=$(uname -r)
note "# stress / kernel $KV"

dnf -y -q install epel-release
dnf -y -q install patch ntfs-3g ntfsprogs qemu-img gcc make git autoconf \
	automake libtool libuuid-devel xfsprogs-devel libaio-devel \
	elfutils-libelf-devel rpm cpio xz tar bison flex
# fsx と fsstress は xfstests の ltp/ に在る。版を固定し、何で測ったかを残す。
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

if [ "${FS_PATCH:-0}" = 1 ]; then
	. $here/ksrc.sh
	fs_build ntfs3 $out/ntfs3-build.log
	note "ntfs3 build+insmod exit $?"
fi
drivers=ntfs-3g
for m in ntfs3 ntfs; do
	modprobe $m 2>/dev/null && drivers="$drivers $m"
done
note "ntfs drivers: $drivers"
dmesg -c > /dev/null

# alma.sh の nmount と同じ理由で、カーネルのドライバは mount -i で呼び、
# /proc/mounts の種別を確かめる。
nmount() {	# driver dev
	case $1 in
	ntfs-3g) ntfs-3g $2 /mnt/p; want=fuseblk ;;
	*)       mount -i -t $1 $2 /mnt/p; want=$1 ;;
	esac || return 1
	got=$(awk '$2 == "/mnt/p" { print $3 }' /proc/mounts)
	[ "$got" = "$want" ] || { echo "!! /mnt/p is $got, not $want" >&2; umount /mnt/p; return 1; }
}
# 名前、大きさ、中身の hash。fsstress の作るものは名前も中身も種で決まる。
tree() { (cd /mnt/p && find . -xdev ! -name . -printf '%y %s %p\n' | LC_ALL=C sort &&
	find . -xdev -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum) 2>&1; }

for drv in $drivers; do
	note ""
	note "### $drv"
	raw=$work/stress-$drv.raw
	rm -f $raw
	truncate -s 2G $raw
	echo 'type=7' | sfdisk -q $raw
	loop=$(losetup -f -P --show $raw)
	mkntfs -Q -L STRESS ${loop}p1 > $out/stress-$drv.mkntfs 2>&1
	if ! nmount $drv ${loop}p1 2> $out/stress-$drv.err; then
		note "!! mount failed: $(tail -1 $out/stress-$drv.err)"
		losetup -d $loop
		continue
	fi
	# fsx: 三つの種で、mmap も含めて。fallocate、punch hole、zero range、
	# collapse/insert range はドライバが受けるかを fsx 自身が確かめて使う。
	for seed in 1 2 3; do
		f=/mnt/p/fsx.$seed
		timeout 900 $fsx -q -N 30000 -S $seed -l 8388608 $f \
			> $out/stress-$drv.fsx$seed 2>&1
		st=$?
		note "fsx seed $seed: exit $st $(grep -E 'ops|LOG DUMP|READ BAD|Size error|error' $out/stress-$drv.fsx$seed | head -2 | tr '\n' ';')"
	done
	# fsstress: 4 本並行。終わったら中身を取り、remount してもう一度取る。
	timeout 900 $fsstress -d /mnt/p/fss -n 4000 -p 4 -s 1 \
		> $out/stress-$drv.fsstress 2>&1
	note "fsstress: exit $?"
	sync
	tree > $out/stress-$drv.tree1
	umount /mnt/p
	echo 3 > /proc/sys/vm/drop_caches
	if nmount $drv ${loop}p1 2>> $out/stress-$drv.err; then
		tree > $out/stress-$drv.tree2
		umount /mnt/p
		note "after remount: differing lines $(diff $out/stress-$drv.tree1 $out/stress-$drv.tree2 | grep -c '^[<>]') of $(wc -l < $out/stress-$drv.tree1)"
		diff $out/stress-$drv.tree1 $out/stress-$drv.tree2 | grep '^[<>]' | head -6 | cut -c1-160 | tee -a $sum
	else
		note "!! remount failed: $(tail -1 $out/stress-$drv.err)"
	fi
	ntfsfix -n ${loop}p1 > $out/stress-$drv.ntfsfix 2>&1
	note "ntfsfix -n exit $?"
	dmesg -c > $out/stress-$drv.dmesg
	note "dmesg: $(grep -ciE 'warning|bug|error|corrupt|oops|call trace' $out/stress-$drv.dmesg) suspicious lines"
	grep -iE 'warning|bug|error|corrupt|oops|call trace' $out/stress-$drv.dmesg | head -8 | cut -c1-200 | sed 's/^/    /' | tee -a $sum
	losetup -d $loop
	qemu-img convert -f raw -O vpc -o subformat=fixed,force_size=on $raw $out/stress-$drv.vhd
	rm -f $raw
done
