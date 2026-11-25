#!/bin/sh
# FreeBSD の上で、NetBSD が書いた FFSv1 を読み、次に rw で mount して触る。
# fbin/d1.raw.gz (-O 1) と fbin/d2.raw.gz (-O 0) を読み、触った後のものを
# fbout/d<n>-<時計の年>.raw.gz に置く。時計は今のままと 2040 年の二通り。
# 2040 年の方は file の日付 (2040-01-02) の翌日にする。同じ日だと、数秒の差で
# 「今より先」になったりならなかったりする。
uname -a; export TZ=UTC
mkdir -p fbout
real=$(date -u +%Y%m%d%H%M.%S)
show() {
	for f in /mnt/[a-z]*; do
		[ -f $f ] || continue
		echo "T $1 ${f#/mnt/} $(stat -f '%m %Sm atime %a %Sa nsec %Fm' -t %Y-%m-%d $f | sed 's/nsec [^.]*\./nsec /')"
	done
}
{
for y in 2026 2040; do
	[ $y = 2040 ] && date 204001030304 > /dev/null
	echo "T now $(date)"
	for i in 1 2; do
		n=fbsd$y-d$i
		gunzip -c fbin/d$i.raw.gz > d.img; md=$(mdconfig -a -t vnode -f d.img)
		if mount -t ufs -o ro /dev/$md /mnt; then
			show "$n ro"
			rc=0; cp -p /mnt/w2040 c1 > cp.log 2>&1 || rc=$?
			echo "T $n cp -p exit $rc $(cat cp.log) $(stat -f %Sm -t %Y-%m-%d c1)"; rm -f c1
			umount /mnt
		else
			echo "T $n ro mount failed"
		fi
		rc=0; fsck_ffs -fn /dev/$md > f.txt 2>&1 || rc=$?
		echo "T $n fsck before $rc $(grep -vE '^\*\*|^$|files,' f.txt | head -3 | tr '\n' ';')"
		if mount -t ufs -o rw /dev/$md /mnt; then
			# 読むだけ。inode を読み込んだときに書き換わるかを見る
			ls -l /mnt > /dev/null
			# 中身に触る
			echo more >> /mnt/t1960; echo more >> /mnt/t2040
			cat /mnt/r2040 > /dev/null
			echo new > /mnt/fbnew
			sync
			show "$n rw"
			umount /mnt
			rc=0; fsck_ffs -fn /dev/$md > f.txt 2>&1 || rc=$?
			echo "T $n fsck after $rc $(grep -vE '^\*\*|^$|files,' f.txt | head -3 | tr '\n' ';')"
		else
			echo "T $n rw mount failed"
		fi
		mdconfig -d -u $md
		gzip -c d.img > fbout/d$i-$y.raw.gz; rm -f d.img
	done
done
date $real > /dev/null
echo "T now $(date)"
echo "T FBSDDONE"
} 2>&1 | tee fbout/fbsd.log
