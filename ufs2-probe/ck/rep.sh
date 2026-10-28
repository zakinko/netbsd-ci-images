#!/bin/sh
# Runs inside the guest as root: rep.sh <n>
# The soft-limit quota cases, n times each with the snapshot's
# librumpfs_ffs and with hf/, alternating; output of every failure kept.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
cd /root/p/ck || exit 1
L=$(ls /usr/lib/librumpfs_ffs.so.*.* | head -1)
[ -f $L.snap ] || cp $L $L.snap
xz -dc hf/librumpfs_ffs-*.so.xz > $L.hf || exit 1
O=/root/p/rep; mkdir -p $O
T=/usr/tests/fs/ffs
tcs=$(cd $T && ./t_quotalimit -l | awk '/^ident: slimit/{print $2}')
echo "cases: $tcs" | tr '\n' ' '; echo
i=0
while [ $i -lt $1 ]; do
	i=$((i+1))
	for lib in snap hf; do
		cp $L.$lib $L
		for tc in $tcs; do
			w=$(mktemp -d /tmp/rep.XXXXXX)
			(cd $w && $T/t_quotalimit -s $T -r $w/res $tc > $w/out 2>&1)
			r=$(head -1 $w/res | cut -d: -f1)
			echo "$lib $tc $r"
			[ "$r" = passed ] || { cp $w/out $O/$lib-$tc-$i.out; cat $w/res >> $O/$lib-$tc-$i.out; }
			rm -rf $w
		done
	done
done | sort | uniq -c
cp $L.snap $L
for f in $O/*.out; do [ -f "$f" ] && { echo "== $f"; tail -15 $f; }; done | head -80
