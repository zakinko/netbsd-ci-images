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
# read_pages は RSP を RBP から戻す (lea -0x18(%rbp),%rsp)。落ちた RSP は
# 本来の値より 1 少なかった。mpage_readahead から戻った時点で RBP が既に
# ずれているのかを分ける。
cat > $work/rbp.h <<'EOH'
/* volatile のメモリに取る。レジスタに取ると RBP 同士を比べてしまう
 * (run 41987982347)。自分で RBP を積むだけで read_pages へ届かなくなり、
 * ずれは出口で消される。死んだ下のフレームごと出す。 */
#define RA_CHECK(call, inode) do {					\
	volatile unsigned long ra_b, ra_a;				\
	unsigned long ra_sp;						\
	asm volatile("mov %%rbp,%0" : "=m"(ra_b));			\
	call;								\
	asm volatile("mov %%rbp,%0" : "=m"(ra_a));			\
	asm volatile("mov %%rsp,%0" : "=r"(ra_sp));			\
	if (ra_a != ra_b) {						\
		pr_emerg("ra-panic: rbp %lx -> %lx sp %lx ino %lx\n",	\
			 ra_b, ra_a, ra_sp, (inode)->i_ino);		\
		print_hex_dump(KERN_EMERG, "ra-stack ", DUMP_PREFIX_ADDRESS, \
			       32, 8, (void *)(ra_sp - 0x200), 0x300, false); \
		panic("ra-panic");					\
	}								\
} while (0)
EOH
sed -i "1i #include \"$work/rbp.h\"" $ksrc/ntfs3/inode.c
sed -i 's|^\tmpage_readahead(rac, ntfs_get_block);|\tRA_CHECK(mpage_readahead(rac, ntfs_get_block), inode);|' $ksrc/ntfs3/inode.c
grep -c 'RA_CHECK(mpage' $ksrc/ntfs3/inode.c | tee -a $sum
fs_build ntfs3 $out/ntfs3-build.log
st=$?
note "ntfs3 build+insmod exit $st"
[ $st = 0 ] && [ -d /sys/module/ntfs3 ] || exit 1
grep -n 'blk_start_plug\|blk_finish_plug\|bio_chain\|submit_bio' $ksrc/ntfs3/*.c | sed 's/^/PLUG /'
note "ntfs3 taint: '$(cat /sys/module/ntfs3/taint)'"
modprobe -q xfs
grep -E '^(ntfs3|xfs) ' /proc/modules | tee -a $sum
# 戻り番地は run ごとに上位だけ変わり、下 21 bit は 0x1f7a79 で揃う。
# モジュールではなく、2MB 単位で動く vmlinux の中である。そこを読む。
map=/usr/src/kernels/$(uname -r)/System.map
ret=$(awk '$2 ~ /[tT]/ && $3 == "page_cache_ra_unbounded" { print $1 }' $map)
note "page_cache_ra_unbounded in System.map: $ret"
sh /usr/src/kernels/$(uname -r)/scripts/extract-vmlinux /boot/vmlinuz-$(uname -r) > $work/vmlinux
objdump -d --no-show-raw-insn --start-address=0x$ret --stop-address=0x$(printf %x $((0x$ret + 0x200))) $work/vmlinux |
	tee $out/ra-unbounded.dis | sed 's/^/DIS /'
# ntfs_readahead は mpage_readahead へ tail call なので、ret を実行したのは
# mpage_readahead である。
# 戻り先の直前の call は read_pages で、壊れた R12 もその呼び出し元が
# 積んだ値だった。read_pages を生の byte ごと出す。
for f in read_pages; do
	l=$(awk -v f=$f '$3 == f { print $1 }' $map)
	objdump -d --start-address=0x$l --stop-address=0x$(printf %x $((0x$l + 0x200))) $work/vmlinux | sed 's/^/DISR /'
done
for f in mpage_readahead do_mpage_readpage; do
	l=$(awk -v f=$f '$3 == f { print $1 }' $map)
	# 番地は 64 bit の上位が立っていて、printf %d では飽和する。16 進のまま渡す。
	objdump -d --no-show-raw-insn --start-address=0x$l --stop-address=0x$(printf %x $((0x$l + 0x900))) $work/vmlinux |
		awk -v f=$f 'NR > 6 && /\tint3/ { exit } { print f " " $0 }' | sed 's/^/DISV /'
done
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
	case ${RA_FS:-ntfs3} in
	ntfs3)	mkntfs -Q -L STRESS ${loop}p1 > /dev/null 2>&1
		mount -i -t ntfs3 ${loop}p1 /mnt/p || { note "!! mount failed"; exit 1; } ;;
	ext4)	mkfs.ext4 -q ${loop}p1
		mount ${loop}p1 /mnt/p || { note "!! mount failed"; exit 1; } ;;
	esac
	timeout 300 $fsstress -d /mnt/p/fss -n 4000 -p 4 -s $i > /dev/null 2>&1
	sync
	for r in 1 2 3; do
		echo 3 > /proc/sys/vm/drop_caches
		# 落ちたファイルが serial に残るよう、一本ずつ読む。
		(cd /mnt/p && find . -xdev -type f -printf '%i %s %p\n') | while read ino size f; do
			echo "ra-panic: read $ino $size $f" > /dev/kmsg
			(cd /mnt/p && ${RA_READER:-sha256sum} "$f") > /dev/null 2>&1
		done
	done
	umount /mnt/p
	losetup -d $loop
	note "iteration $i done"
done
dmesg > $out/dmesg.txt
note "all $n iterations finished; oops lines: $(grep -cE 'Oops|BUG:' $out/dmesg.txt)"
grep -n -A45 -E 'Oops|BUG:' $out/dmesg.txt | head -120 | cut -c1-150 | sed 's/^/OOPS /'
