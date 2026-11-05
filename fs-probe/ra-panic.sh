#!/bin/sh
# ntfs3 の fsstress の後に drop_caches して読み直すのを繰り返す。
#   ra-panic.sh <outdir> <回数>
# run 41539207653 の alma (rhel) で、この読み直しの sha256sum が
# RSP の奇数番地 (0x...9df) で ret し panic した。同じ commit の次の
# run では出ていない。当て物の無い ntfs3 でも出るのかを回数で比べる。
# RHEL の kernel に ntfs3 は無いので、stock もソースから建てる。
set -u
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$1"
out=$(cd "$1" && pwd)
n=$2
work=/var/tmp/fsp
mkdir -p $work /mnt/p
sum=$out/summary.txt
: > $sum
note() { printf '%s\n' "$*" | tee -a $sum; }
note "# ra-panic / kernel $(uname -r) FS_PATCH=${FS_PATCH:-0} OMIT=${FS_PATCH_OMIT:-}"

dnf -y -q install epel-release
dnf -y -q install patch ntfs-3g ntfsprogs gcc make git autoconf automake libtool \
	libuuid-devel xfsprogs-devel libaio-devel libacl-devel libattr-devel \
	elfutils-libelf-devel rpm cpio xz tar bison flex binutils gawk
xfstests_tag=v2026.10.15
git clone -q --depth 1 --branch $xfstests_tag \
	https://git.kernel.org/pub/scm/fs/xfs/xfstests-dev.git $work/xfstests
(cd $work/xfstests && make configure && ./configure && make -C lib &&
	make -C ltp fsstress) > $out/xfstests-build.log 2>&1
fsstress=$work/xfstests/ltp/fsstress
[ -x $fsstress ] || { note "!! fsstress did not build"; exit 1; }

. $here/ksrc.sh
fs_sparse || exit 1
fs_build ntfs3 $out/ntfs3-build.log
st=$?
note "ntfs3 build+insmod exit $st"
[ $st = 0 ] && [ -d /sys/module/ntfs3 ] || exit 1
note "ntfs3 taint: '$(cat /sys/module/ntfs3/taint)'"
modprobe -q xfs
grep -E '^(ntfs3|xfs) ' /proc/modules | tee -a $sum
MODRET_KO_ntfs3=$ksrc/ntfs3/ntfs3.ko sh $here/modret.sh a79 ntfs3 xfs | tee -a $sum

dmesg -n 8
raw=$work/ra.raw
i=0
while [ $i -lt $n ]; do
	i=$((i + 1))
	echo "ra-panic: iteration $i" > /dev/kmsg
	rm -f $raw
	truncate -s 2G $raw
	echo 'type=7' | sfdisk -q $raw
	loop=$(losetup -f -P --show $raw)
	mkntfs -Q -L STRESS ${loop}p1 > /dev/null 2>&1
	mount -i -t ntfs3 ${loop}p1 /mnt/p || { note "!! mount failed"; exit 1; }
	timeout 300 $fsstress -d /mnt/p/fss -n 4000 -p 4 -s $i > /dev/null 2>&1
	sync
	for r in 1 2 3; do
		echo 3 > /proc/sys/vm/drop_caches
		(cd /mnt/p && find . -xdev -type f -print0 | xargs -0 -r sha256sum) > /dev/null 2>&1
	done
	umount /mnt/p
	losetup -d $loop
	note "iteration $i done"
done
dmesg > $out/dmesg.txt
note "all $n iterations finished; oops lines: $(grep -cE 'Oops|BUG:' $out/dmesg.txt)"
