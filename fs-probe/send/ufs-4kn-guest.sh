#!/bin/sh
# mainline の ufs を、論理ブロック 512 と 4096 の loop で読み書きする。
#   4kn-guest.sh <image の dir> <out> <label>
in=$1 out=$2 label=$3
here=$(cd "$(dirname "$0")/.." && pwd)
w=/run/w
mkdir -p "$out" $w && mount -t tmpfs -o size=6g none $w && mkdir $w/m
sum=$out/$label.txt; : > $sum
note() { printf '%s\n' "$*" | tee -a $sum; }
note "# $label kernel $(uname -r) $(uname -v)"
for n in freebsd-ufs2 freebsd-ufs1 netbsd-ffs2 netbsd-ffs1; do
	case $n in *ffs1|*ufs1) t=44bsd ;; *) t=ufs2 ;; esac
	for ss in 512 4096; do
		cp --sparse=always $in/$n.img $w/i.img
		l=$(losetup -f --show --sector-size $ss $w/i.img) || { note "!! losetup"; exit 1; }
		note "## $n sector $(blockdev --getss $l)"
		dmesg -C
		if mount -t ufs -o ro,ufstype=$t $l $w/m 2>/dev/null; then
			sh $here/manifest.sh $w/m/src > $w/ro
			note "ro: mounted, files $(grep -c '^H' $w/ro), differing $(diff $in/$n.manifest $w/ro | grep -c '^[<>]')"
			diff $in/$n.manifest $w/ro | grep '^[<>]' | head -4 | tee -a $sum
			umount $w/m
		else
			note "ro: not mounted: $(dmesg | tail -2 | sed 's/^\[[^]]*\] //' | tr '\n' ';')"
		fi
		if mount -t ufs -o rw,ufstype=$t $l $w/m 2>/dev/null; then
			sh $here/mktree.sh $w/m/linux > $w/mk 2>&1
			note "rw: mktree exit $?"
			sh $here/manifest.sh $w/m/linux > $w/a
			umount $w/m; echo 3 > /proc/sys/vm/drop_caches
			mount -t ufs -o ro,ufstype=$t $l $w/m
			sh $here/manifest.sh $w/m/linux > $w/b
			sh $here/manifest.sh $w/m/src > $w/c
			note "rw: after remount linux/ differing $(diff $w/a $w/b | grep -c '^[<>]') of $(wc -l < $w/a), src/ differing $(diff $w/ro $w/c | grep -c '^[<>]')"
			umount $w/m
			case $n in freebsd-*) gzip -1 -c $w/i.img > $out/$label-$n-$ss.img.gz ;; esac
		else
			note "rw: not mounted"
		fi
		dmesg | grep -iE 'ufs|WARNING|BUG' | head -4 | tee -a $sum
		losetup -d $l
	done
done
