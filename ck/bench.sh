#!/bin/sh
# Runs as root inside a trunk chroot: bench.sh <label> <tar>
# Times FFS on memory-backed images (tmpfs under vnd), so that what is
# measured is the file system's CPU work, not the disk:
#   plain        newfs -O2 -b 32k -f 4k, 1 GB
#   plain+log    the same with -o log
#   ckhash       the same given metadata check-hashes (only where the
#                kernel has them)
#   ckhash+log   the same with -o log
# Each run gets a new file system.  The image stays at 1 GB: tmpfs
# charges the whole length of a file when it is extended.
# Workloads: 512 MB sequential write, read after a remount, extract
# <tar> (many small files), find over it, remove it; then fsck_ffs -F -f -n
# of a new plain file system with <tar> extracted five times.  Three rounds each.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
L=$1
TAR=$2
W=/tmp/bench
M=$W/m
SB=65536
rm -rf $W; mkdir -p $M; cd $W || exit 1

# od pads with zeros; read the number as decimal, not octal
get32() { od -An -tu4 -j $2 -N4 $1 | awk '{ print $1 + 0 }'; }
put32() {
	v=$3
	printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $((v & 255)) \
	    $((v >> 8 & 255)) $((v >> 16 & 255)) $((v >> 24 & 255)))" |
	    dd of=$1 bs=1 seek=$2 conv=notrunc 2>/dev/null
}
t() {	# label command...: one line with real/user/sys and exit status
	lab=$1; shift
	# The command's own output is thrown away; only time(1) speaks.
	tm=$(/usr/bin/time -p sh -c "{ $*; } >/dev/null 2>&1; echo \$? > $W/rc" 2>&1)
	rc=$(cat $W/rc)
	[ "$rc" = 0 ] && rc= || rc=" rc=$rc"
	echo $tm | awk -v l="$lab" -v rc="$rc" \
	    '{ printf "%-28s real %6s user %6s sys %6s%s\n", l, $2, $4, $6, rc }'
}

mkimg() {	# ckhash: 0 or 1
	rm -f fs.img
	# Make the file first: when newfs makes it, writes through vnd to
	# it take ten times as long (21 s for 512 MB, against 2 s).
	dd if=/dev/zero of=fs.img bs=1m count=1 seek=1023 2>/dev/null
	newfs -F -s 1g -O2 -b 32k -f 4k fs.img > /dev/null || return 1
	[ $1 = 1 ] || return 0
	put32 fs.img $((SB + 1308)) 7
	put32 fs.img $((SB + 1312)) $(($(get32 fs.img $((SB + 1312))) | 512))
	fsck_ffs -F -f -y fs.img > /dev/null 2>&1
}

echo "=== bench $L: $(uname -v)"
mkimg 0 || exit 1
echo "cgsize $(get32 fs.img $((SB + 160))) ncg $(get32 fs.img $((SB + 44)))"

run() {	# ckhash tag [mount options]
	ck=$1; tag=$2; shift 2
	mkimg $ck || { echo "$tag: newfs failed"; return; }
	vnconfig vnd2 fs.img || return
	if ! mount -t ffs "$@" /dev/vnd2a $M; then
		echo "$tag: mount $* failed"; vnconfig -u vnd2; return
	fi
	t "$tag write-512m" "dd if=/dev/zero of=$M/big bs=64k count=8192 2>/dev/null; sync"
	umount $M; mount -t ffs "$@" /dev/vnd2a $M
	t "$tag read-512m" "dd if=$M/big of=/dev/null bs=64k 2>/dev/null"
	rm $M/big; sync
	t "$tag extract" "tar -xf $TAR -C $M; sync"
	t "$tag find" "find $M | wc -l"
	t "$tag remove" "rm -rf $M/usr; sync"
	umount $M; vnconfig -u vnd2
}
for r in 1 2 3; do
	run 0 "$r plain"
	run 0 "$r plain+log" -o log
	case $L in
	stock*)	;;	# the stock kernel cannot keep check-hashes
	*)	run 1 "$r ckhash"
		run 1 "$r ckhash+log" -o log ;;
	esac
done
# Five copies of <tar>: one alone is checked in 0.01 seconds.
mkimg 0 && vnconfig vnd2 fs.img && mount -t ffs /dev/vnd2a $M &&
    for i in 1 2 3 4 5; do mkdir $M/$i; tar -xf $TAR -C $M/$i; done &&
    umount $M; vnconfig -u vnd2
echo "files for fsck: $(fsck_ffs -F -f -n fs.img 2>&1 | grep 'files,')"
for r in 1 2 3; do
	t "$r fsck -f -n" "fsck_ffs -F -f -n fs.img"
done
rm -f fs.img
