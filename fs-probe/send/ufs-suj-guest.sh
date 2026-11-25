#!/bin/sh
# SUJ の付いた UFS を rw で書いている最中のディスクを写す。
#   ufs-suj-guest.sh <image の dir> <out> <label>
in=$1 out=$2 label=$3
here=$(cd "$(dirname "$0")" && pwd)
w=/run/w
mkdir -p "$out" $w && mount -t tmpfs -o size=7g none $w && mkdir -p $w/m
sum=$out/$label.txt; : > $sum
note() { printf '%s\n' "$*" | tee -a $sum; }
note "# $label kernel $(uname -r) $(uname -v)"
echo 20 > /proc/sys/vm/dirty_writeback_centisecs
echo 40 > /proc/sys/vm/dirty_expire_centisecs
work() {
	i=0
	while [ ! -e $w/stop ]; do
		i=$((i + 1)); d=$w/m/w$1; mkdir -p $d/a$((i % 7))
		for j in 1 2 3 4 5 6 7 8 9; do
			head -c $((j * 3000 + i % 5000)) /dev/zero > $d/a$((i % 7))/f$j-$i 2>/dev/null
			[ $j = 5 ] && mv $d/a$((i % 7))/f4-$i $d/r$((i % 11)) 2>/dev/null
		done
		rm -rf $d/a$(((i + 3) % 7))
	done
}
for n in freebsd-ufs2-suj freebsd-ufs2-nohash freebsd-ufs1-suj; do
	src=$n; t=ufs2
	case $n in *nohash) src=freebsd-ufs2-suj ;; *ufs1*) t=44bsd ;; esac
	[ -e $in/$src.img ] || { note "!! no $src.img"; continue; }
	for c in 1 2 3; do
		cp --sparse=always $in/$src.img $w/i.img
		case $n in *nohash) python3 $here/ufs-suj-poke.py nohash $w/i.img ;; esac
		rm -f $w/stop
		l=$(losetup -f --show $w/i.img)
		dmsetup create suj --table "0 $(blockdev --getsz $l) linear $l 0" || { note "!! dmsetup"; exit 1; }
		if mount -t ufs -o rw,ufstype=$t /dev/mapper/suj $w/m; then
			note "## $n $c mounted $(awk -v m=$w/m '$2 == m { print $4 }' /proc/mounts)"
			for k in 1 2 3 4 5 6; do work $k & done
			sleep $((c * 4 + 5))
			dmsetup suspend --noflush --nolockfs suj
			cp --sparse=always $w/i.img $w/copy.img
			dmsetup resume suj
			: > $w/stop; wait
			umount $w/m
			gzip -1 -c $w/copy.img > $out/$label-$n-$c.img.gz
			gzip -1 -c $w/i.img > $out/$label-$n-$c-umounted.img.gz
			[ $c = 1 ] || rm -f $out/$label-$n-$c-umounted.img.gz
			rm -f $w/copy.img
		else
			note "!! mount $n: $(dmesg | tail -2 | tr '\n' ';')"
		fi
		dmsetup remove suj; losetup -d $l
		dmesg -c | grep -E 'WARNING|BUG|Oops|ufs.*(error|panic)' | head -3 | tee -a $sum
	done
done

# mount の経路。UFS2 は check hash を切ったもの。
poke() { python3 $here/ufs-suj-poke.py "$@"; }
opts() { awk -v m=$w/m '$2 == m { print substr($4, 1, 2) }' /proc/mounts; }
for n in freebsd-ufs2-suj freebsd-ufs1-suj; do
	case $n in *ufs1*) t=44bsd ;; *) t=ufs2 ;; esac
	new() { cp --sparse=always $in/$n.img $w/i.img; [ $t = 44bsd ] || poke nohash $w/i.img; dmesg -C; }
	loopon() { l=$(losetup -f --show $w/i.img); dmsetup create suj --table "0 $(blockdev --getsz $l) linear $l 0"; }
	loopoff() { dmsetup remove suj; losetup -d $l; }
	save() { gzip -1 -c $1 > $out/$label-$n-$2.img.gz; }
	D=/dev/mapper/suj
	note "## paths $n"
	# P1: ro -> rw -> ro -> rw、書いている最中と remount ro の直後を写す
	new; loopon; rm -f $w/stop
	mount -t ufs -o ro,ufstype=$t $D $w/m; note "P1 ro $(opts) clean $(poke get $w/i.img)"
	mount -o remount,rw $w/m; note "P1 remount rw exit $? $(opts) clean $(poke get $w/i.img)"
	for k in 1 2 3 4 5 6; do work $k & done
	sleep 10; dmsetup suspend --noflush --nolockfs suj; cp --sparse=always $w/i.img $w/copy.img; dmsetup resume suj
	: > $w/stop; wait; save $w/copy.img p1-busy
	mount -o remount,ro $w/m; note "P1 remount ro exit $? $(opts) clean $(poke get $w/i.img)"
	cp --sparse=always $w/i.img $w/copy.img; save $w/copy.img p1-ro
	mount -o remount,rw $w/m; note "P1 remount rw again exit $? clean $(poke get $w/i.img)"
	umount $w/m; note "P1 umount clean $(poke get $w/i.img)"; loopoff
	# P2: clean でないものを remount rw して書き、umount する
	new; poke clean $w/i.img 0; loopon
	mount -t ufs -o rw,ufstype=$t $D $w/m; note "P2 mount of clean 0: $(opts)"
	mount -o remount,rw $w/m; note "P2 remount rw exit $? $(opts)"
	mkdir $w/m/p2 && echo x > $w/m/p2/f; umount $w/m; note "P2 umount clean $(poke get $w/i.img)"; loopoff
	save $w/i.img p2
	# P3: NetBSD の 2
	new; poke clean $w/i.img 2; loopon
	mount -t ufs -o rw,ufstype=$t $D $w/m; note "P3 mount of clean 2: $(opts) clean $(poke get $w/i.img)"
	umount $w/m; note "P3 umount clean $(poke get $w/i.img)"; loopoff
	# P4: ufs_error
	new; poke allfree $w/i.img; loopon
	mount -t ufs -o rw,ufstype=$t $D $w/m; note "P4 mount $(opts)"
	rm -rf $w/m/src $w/m/misc; sync; note "P4 after rm clean $(poke get $w/i.img): $(dmesg | grep -iE 'ufs.*error|panic' | head -1 | cut -c1-120)"
	umount $w/m; note "P4 umount clean $(poke get $w/i.img): $(dmesg | grep -iE 'not marking' | head -1 | cut -c1-120)"; loopoff
	dmesg -c | grep -E 'WARNING|BUG|Oops' | head -3 | tee -a $sum
done
