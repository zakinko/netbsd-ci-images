# -o sync で、間接ブロックを持つファイルの作成と削除を繰り返し、中身を照合する。
# 解放した間接ブロックの buffer が block device の cache に残っているまま
# 取り直されることが肝なので、drop_caches はしない。
zsync() {	# dev name
	mount -t ufs -o rw,sync,ufstype=ufs2 /dev/$1 $w/m || { note "!! mount $2 sync"; exit 1; }
	rm -rf $w/m/zs; mkdir $w/m/zs; bad=0 n=0 lost=0
	rm -f $w/zs.sum
	for r in $(seq 1 12); do
		for i in 1 2 3 4 5 6; do
			c=$(( (r * 7 + i * 13) % 40 + 4 ))
			dd if=/dev/urandom of=$w/m/zs/f$i bs=32k count=$c status=none || lost=$((lost + 1))
			echo "$(sha256sum < $w/m/zs/f$i | cut -d' ' -f1) f$i" > $w/zs.f$i
		done
		for i in 1 2 3 4 5 6; do
			n=$((n + 1)); [ "$(sha256sum < $w/m/zs/f$i | cut -d' ' -f1) f$i" = "$(cat $w/zs.f$i)" ] || bad=$((bad + 1))
		done
		for i in $(seq 1 6); do [ $(( (r + i) % 2 )) = 0 ] && rm -f $w/m/zs/f$i && rm -f $w/zs.f$i; done
		for f in $w/zs.f*; do i=${f##*zs.f}; [ -e $f ] || continue
			n=$((n + 1)); [ "$(sha256sum < $w/m/zs/f$i | cut -d' ' -f1) f$i" = "$(cat $f)" ] || bad=$((bad + 1)); done
	done
	umount $w/m; echo 3 > /proc/sys/vm/drop_caches; mount -t ufs -o ro,ufstype=ufs2 /dev/$1 $w/m; rb=0
	for f in $w/zs.f*; do i=${f##*zs.f}; [ -e $f ] || continue; [ "$(sha256sum < $w/m/zs/f$i | cut -d' ' -f1) f$i" = "$(cat $f)" ] || rb=$((rb + 1)); done
	umount $w/m
	note "$2 sync: wrong $bad of $n checks, wrong after remount $rb, failed writes $lost"
	dmesg | grep -iE 'ufs.*(error|panic|free|alloc)|WARNING:|BUG:' | head -4 | tee -a $sum
	case $2 in freebsd-*) gzip -1 -c /dev/$1 > $out/$label-$2-sync.img.gz ;; esac
}
