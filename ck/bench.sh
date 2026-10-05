#!/bin/sh
# Runs as root inside a trunk chroot: bench.sh <label> <tar>
# Times FFS on memory-backed images (tmpfs under vnd), so that what is
# measured is the file system's CPU work, not the disk:
#   pa   newfs -O2 -b 32k -f 4k, 8 GB (32 KB cylinder groups)
#   pa   the same with -o log
#   pb   pa given metadata check-hashes (only where the kernel has them)
#   pb   the same with -o log
# Workloads: 512 MB sequential write, read after a remount, extract
# <tar> (many small files), find over it, remove it; then fsck_ffs -F -f -n
# of pa with <tar> extracted.  Three rounds each.
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
t() {	# label command...: one line with real/user/sys
	lab=$1; shift
	# The command's own output is thrown away; only time(1) speaks.
	/usr/bin/time -p sh -c "{ $*; } >/dev/null 2>&1" 2>&1 | tr '\n' ' ' |
	    awk -v l="$lab" '{ printf "%-28s real %6s user %6s sys %6s\n", l, $2, $4, $6 }'
}

echo "=== bench $L: $(uname -v)"
for i in pa pb; do	# not cp: it would write the 8 GB of holes
	dd if=/dev/zero of=$i.img bs=1m count=1 seek=8191 2>/dev/null
	newfs -F -s 8g -O2 -b 32k -f 4k $i.img > /dev/null
done
put32 pb.img $((SB + 1308)) 7
put32 pb.img $((SB + 1312)) $(($(get32 pb.img $((SB + 1312))) | 512))
fsck_ffs -F -f -y pb.img > /dev/null 2>&1
echo "cgsize $(get32 pa.img $((SB + 160))) ncg $(get32 pa.img $((SB + 44)))"

run() {	# img tag [mount options]
	img=$1; tag=$2; shift 2
	vnconfig vnd2 $img || return
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
	run pa.img "$r plain"
	run pa.img "$r plain+log" -o log
	case $L in
	stock*)	;;	# the stock kernel cannot write pb
	*)	run pb.img "$r ckhash"
		run pb.img "$r ckhash+log" -o log ;;
	esac
done
vnconfig vnd2 pa.img && mount -t ffs /dev/vnd2a $M &&
    tar -xf $TAR -C $M && umount $M; vnconfig -u vnd2
echo "files for fsck: $(fsck_ffs -F -f -n pa.img 2>&1 | grep 'files,')"
for r in 1 2 3; do
	t "$r fsck -f -n" "fsck_ffs -F -f -n pa.img"
done
rm -f pa.img pb.img
