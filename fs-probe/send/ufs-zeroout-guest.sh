#!/bin/sh
# 128MiB の連続書きと読みを 5 回ずつ、0 埋めの漏れ、読み戻しの照合。
#   ufs-perf-guest.sh <in> <out> <label>   /dev/vda = netbsd-ffs2、/dev/vdb = freebsd-ufs2
in=$1 out=$2 label=$3
here=$(cd "$(dirname "$0")/.." && pwd)
w=/run/w
mkdir -p "$out" $w && mount -t tmpfs -o size=3g none $w && mkdir $w/m $w/ref
mount -t tmpfs none /var/tmp
sum=$out/$label.txt; : > $sum
note() { printf '%s\n' "$*" | tee -a $sum; }
note "# $label kernel $(uname -r) $(uname -v)"
head -c 134217728 /dev/urandom > $w/src.bin
s=$(sha256sum < $w/src.bin)
now() { date +%s%N; }
for x in vda:netbsd-ffs2 vdb:freebsd-ufs2; do
	d=${x%%:*} n=${x#*:}
	mount -t ufs -o rw,ufstype=ufs2 /dev/$d $w/m || { note "!! mount $n"; exit 1; }
	rm -rf $w/m/src; sync
	wr= rd= bad=0
	for i in 1 2 3 4 5; do
		rm -f $w/m/f; sync; echo 3 > /proc/sys/vm/drop_caches
		a=$(now); dd if=$w/src.bin of=$w/m/f bs=1M conv=fsync 2>/dev/null; b=$(now)
		wr="$wr $((134217728 * 1000 / ((b - a) / 1000) / 1000))"
		echo 3 > /proc/sys/vm/drop_caches
		a=$(now); dd if=$w/m/f of=/dev/null bs=1M 2>/dev/null; b=$(now)
		rd="$rd $((134217728 * 1000 / ((b - a) / 1000) / 1000))"
		echo 3 > /proc/sys/vm/drop_caches
		[ "$(sha256sum < $w/m/f)" = "$s" ] || bad=$((bad + 1))
	done
	note "$n write MB/s:$wr"
	note "$n read MB/s:$rd, reread wrong $bad of 5"
	a=$(now); mkdir $w/m/many; i=0; while [ $i -lt 3000 ]; do head -c 8192 $w/src.bin > $w/m/many/f$i; i=$((i + 1)); done; sync; b=$(now)
	note "$n 3000 files of 8KiB: $(((b - a) / 1000000)) ms"
	rm -rf $w/m/f $w/m/many; sync
	sh $here/zerofill.sh $w/m/z $w/ref > $w/z.txt 2>&1
	note "$n zerofill lines $(wc -l < $w/z.txt), leaking: $(grep -vE 'cached 0, reread 0|: 0 non-zero' $w/z.txt | tr '\n' ';')"
	umount $w/m
	case $n in freebsd-*) gzip -1 -c /dev/$d > $out/$label-$n.img.gz ;; esac
done
dmesg | grep -E 'WARNING:|BUG:|Oops' | head -4 | tee -a $sum
