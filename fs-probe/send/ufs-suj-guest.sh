#!/bin/sh
# SUJ の付いた UFS を rw で書いている最中のディスクを写す。
#   ufs-suj-guest.sh <image の dir> <out> <label>
in=$1 out=$2 label=$3
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
		case $n in *nohash)
			# fs_metackhash を 0、fs_flags を SU|SUJ だけにする
			printf '\0\0\0\0\012\0\0\0' | dd of=$w/i.img bs=1 seek=$((65536 + 1308)) conv=notrunc 2>/dev/null ;;
		esac
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
