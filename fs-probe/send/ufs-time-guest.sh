#!/bin/sh
# UFS1 の 32bit の日付を、2038 年の前後と 1970 年の前で読み書きする。
#   ufs-time-guest.sh <image の dir> <out> <label>
in=$1 out=$2 label=$3
w=/run/w
mkdir -p "$out" $w && mount -t tmpfs -o size=6g none $w && mkdir $w/m
sum=$out/$label.txt; : > $sum
note() { printf '%s\n' "$*" | tee -a $sum; }
note "# $label kernel $(uname -r) $(uname -v)"
for n in freebsd-ufs1 netbsd-ffs1 freebsd-ufs2; do
	case $n in *ffs1|*ufs1) t=44bsd ;; *) t=ufs2 ;; esac
	cp --sparse=always $in/$n.img $w/i.img
	note "## $n"
	grep -E '/t(2040|1960|1970)' $in/$n.manifest | sed 's/^/made as: /' | tee -a $sum
	l=$(losetup -f --show $w/i.img)
	mount -t ufs -o rw,ufstype=$t $l $w/m || { note "!! mount"; continue; }
	for f in $w/m/src/t2040 $w/m/src/t1960; do [ -e $f ] && note "read $(basename $f) $(stat -c %Y $f)"; done
	for d in 1960-01-01 1970-01-02 2038-01-19 2040-01-01 2100-01-01 2110-01-01; do
		touch -d "$d UTC" $w/m/w$d
	done
	for p in cached cold; do
		for f in $w/m/w*; do note "$p $(basename $f) $(stat -c %Y $f) $(date -u -d @$(stat -c %Y $f) +%F)"; done
		umount $w/m; echo 3 > /proc/sys/vm/drop_caches
		mount -t ufs -o ro,ufstype=$t $l $w/m
	done
	umount $w/m; losetup -d $l
	case $n in freebsd-ufs1) gzip -1 -c $w/i.img > $out/$label-$n.img.gz ;; esac
	dmesg | grep -E 'WARNING|BUG' | head -3 | tee -a $sum
done
