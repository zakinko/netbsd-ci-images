#!/bin/sh
# fsstress の後、umount の前後で中身が変わるかを種ごとに数える。
#   ufs-change-blocknr-guest.sh <in> <out> <label>
in=$1 out=$2 label=$3
w=/run/w
mkdir -p "$out" $w && mount -t tmpfs -o size=6g none $w && mkdir $w/m
sum=$out/$label.txt; : > $sum
note() { printf '%s\n' "$*" | tee -a $sum; }
note "# $label kernel $(uname -r) $(uname -v)"
bad=0 total=0
for n in netbsd-ffs2 freebsd-ufs2; do
	for k in $(seq 1 16); do
		cp --sparse=always $in/$n.img $w/i.img
		l=$(losetup -f --show $w/i.img)
		mount -t ufs -o rw,ufstype=ufs2 $l $w/m || { note "!! mount"; exit 1; }
		rm -rf $w/m/src; sync
		timeout 300 $FSSTRESS -d $w/m/fss -n 3000 -p 8 -f truncate=0 -s $k > $w/fss.log 2>&1
		st=$?
		sync
		h() { (cd $w/m && find . -xdev -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum); }
		h > $w/t1; umount $w/m; echo 3 > /proc/sys/vm/drop_caches
		mount -t ufs -o ro,ufstype=ufs2 $l $w/m || { note "!! remount"; exit 1; }
		h > $w/t2; umount $w/m; losetup -d $l
		d=$(diff $w/t1 $w/t2 | grep -c '^<')
		total=$((total + 1)); [ $d = 0 ] || bad=$((bad + 1))
		note "$n seed $k: fsstress $st, files $(wc -l < $w/t1), changed by umount $d"
	done
done
note "rounds with changed files: $bad of $total"
dmesg | grep -E 'WARNING:|BUG:|Oops' | head -4 | tee -a $sum
