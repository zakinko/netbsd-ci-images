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
# 戻り番地は run ごとに上位だけ変わり、下 21 bit は 0x1f7a79 で揃う。
# モジュールではなく、2MB 単位で動く vmlinux の中である。そこを読む。
map=/usr/src/kernels/$(uname -r)/System.map
ret=$(awk '$2 ~ /[tT]/ && $3 == "page_cache_ra_unbounded" { print $1 }' $map)
note "page_cache_ra_unbounded in System.map: $ret"
sh /usr/src/kernels/$(uname -r)/scripts/extract-vmlinux /boot/vmlinuz-$(uname -r) > $work/vmlinux
a=$(printf '%d' 0x$ret)
objdump -d --no-show-raw-insn --start-address=$a --stop-address=$((a + 0x200)) $work/vmlinux |
	tee $out/ra-unbounded.dis | sed 's/^/DIS /'
objdump -dr --no-show-raw-insn $ksrc/ntfs3/ntfs3.ko |
	awk '/^[0-9a-f]+ <(ntfs_readahead|ntfs_get_block|ntfs_get_block_vbo|ntfs_read_folio)[^>]*>:$/ { p = 1 }
	     /^$/ { p = 0 } p' | sed 's/^/DISM /'
sed -n '/^static void ntfs_readahead/,/^}/p' $ksrc/ntfs3/inode.c | sed 's/^/SRC /'

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
		# 落ちたファイルが serial に残るよう、一本ずつ読む。
		(cd /mnt/p && find . -xdev -type f -printf '%i %s %p\n') | while read ino size f; do
			echo "ra-panic: read $ino $size $f" > /dev/kmsg
			(cd /mnt/p && sha256sum "$f") > /dev/null 2>&1
		done
	done
	umount /mnt/p
	losetup -d $loop
	note "iteration $i done"
done
dmesg > $out/dmesg.txt
note "all $n iterations finished; oops lines: $(grep -cE 'Oops|BUG:' $out/dmesg.txt)"
