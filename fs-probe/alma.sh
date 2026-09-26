#!/bin/sh
# AlmaLinux 10 の上で、NTFS (EPEL の ntfs-3g) と UFS/FFS (Alma 自身の
# カーネルソースから建てた fs/ufs) がどこまで使えるかを測る。
#   alma.sh <indir> <outdir>
# indir には BSD と Windows が作ったイメージと manifest が在る。outdir には
# Linux が書き足したイメージと、その manifest と、測った記録を置く。
set -u
here=$(cd "$(dirname "$0")" && pwd)
in=$(cd "$1" && pwd)
mkdir -p "$2"
out=$(cd "$2" && pwd)
work=/var/tmp/fsp
mkdir -p $work /mnt/p
sum=$out/summary.txt
: > $sum
note() { printf '%s\n' "$*" | tee -a $sum; }
KV=$(uname -r)

note "# $(cat /etc/almalinux-release) / kernel $KV"
grep -E 'CONFIG_(NTFS3?|UFS)_FS[ =]' /lib/modules/$KV/config | tee -a $sum

# --- 道具 -------------------------------------------------------------------
dnf -y -q install epel-release
dnf -y -q install ntfs-3g ntfsprogs ntfs-3g-system-compression openssl gcc make \
	elfutils-libelf-devel qemu-img rpm cpio xz tar attr diffutils util-linux \
	xfsprogs bison flex
rpm -q ntfs-3g ntfs-3g-system-compression | tee -a $sum

. $here/ksrc.sh
note "fs source: $ksrc"
ufs_build $out/ufs-build.log
note "ufs build+insmod exit $? ($(grep -c warning: $out/ufs-build.log) warnings)"
# NTFS はカーネルに在るものを全部試す。7.1 で戻った新しい ntfs と ntfs3。
drivers=ntfs-3g
for m in ntfs3 ntfs; do
	modprobe $m 2>/dev/null && drivers="$drivers $m"
done
note "ntfs drivers: $drivers"
for m in ntfs3 ntfs; do
	modinfo $m 2>/dev/null | grep -E '^(filename|version|description):' | sed "s/^/    $m /" | tee -a $sum
done
dmesg -c > $out/dmesg-setup.txt

# --- 共通 -------------------------------------------------------------------
mani() { sh $here/manifest.sh "$1"; }
ndiff() { diff "$1" "$2" | grep -c '^[<>]'; }
drop() { sync; echo 3 > /proc/sys/vm/drop_caches; }
bench() {	# label dir
	drop
	w=$( { dd if=/dev/zero of="$2/bench" bs=1M count=128 conv=fsync 2>&1 >/dev/null; } | tail -1)
	drop
	r=$( { dd if="$2/bench" of=/dev/null bs=1M 2>&1 >/dev/null; } | tail -1)
	rm -f "$2/bench"
	drop
	t0=$(date +%s.%N)
	mkdir "$2/benchmany"; i=0
	while [ $i -lt 5000 ]; do : > "$2/benchmany/f$i"; i=$((i + 1)); done
	sync
	t1=$(date +%s.%N)
	rm -rf "$2/benchmany"; sync
	t2=$(date +%s.%N)
	note "bench $1: write128M [$w] read [$r] create5000 $(echo "$t1 - $t0" | bc)s rm5000 $(echo "$t2 - $t1" | bc)s"
}
dnf -y -q install bc

# --- UFS / FFS --------------------------------------------------------------
note ""
note "## UFS/FFS"
for f in $in/netbsd-*.img $in/freebsd-*.img; do
	[ -e "$f" ] || continue
	n=$(basename $f .img)
	case $n in *ffs1|*ufs1) t=44bsd ;; *) t=ufs2 ;; esac
	note ""
	note "### $n (ufstype=$t)"
	cp --sparse=always $f $work/$n.img
	loop=$(losetup -f --show $work/$n.img)

	if mount -t ufs -o ro,ufstype=$t $loop /mnt/p 2>>$out/$n.err; then
		s=$(date +%s.%N)
		mani /mnt/p/src > $out/$n.alma-ro.manifest 2>>$out/$n.err
		e=$(date +%s.%N)
		diff $in/$n.manifest $out/$n.alma-ro.manifest > $out/$n.ro.diff
		note "ro: mounted; manifest $(echo "$e - $s" | bc)s; differing lines $(grep -c '^[<>]' $out/$n.ro.diff)"
		sed -n '1,12p' $out/$n.ro.diff | tee -a $sum
		umount /mnt/p
	else
		note "!! ro mount failed: $(tail -1 $out/$n.err)"
	fi
	dmesg -c > $out/$n.ro.dmesg

	if mount -t ufs -o rw,ufstype=$t $loop /mnt/p 2>>$out/$n.err; then
		mo=$(awk '$2 == "/mnt/p" { print $4 }' /proc/mounts | cut -d, -f1)
		note "rw: mount says $mo"
		if [ "$mo" = rw ]; then
			sh $here/mktree.sh /mnt/p/linux > $out/$n.mktree 2>&1
			note "rw: mktree exit $? $(head -3 $out/$n.mktree | tr '\n' ' ')"
			mani /mnt/p/linux > $out/$n.linux.manifest 2>>$out/$n.err
			bench "ufs:$n" /mnt/p
			df -k /mnt/p | tail -1 >> $sum
		fi
		umount /mnt/p
		drop
		if mount -t ufs -o ro,ufstype=$t $loop /mnt/p 2>>$out/$n.err; then
			[ -d /mnt/p/linux ] && {
				mani /mnt/p/linux > $out/$n.linux.reread
				note "rw: after remount, linux/ differing lines $(ndiff $out/$n.linux.manifest $out/$n.linux.reread)"
			}
			mani /mnt/p/src > $out/$n.src.reread
			note "rw: after remount, src/ differing from original $(ndiff $in/$n.manifest $out/$n.src.reread)"
			umount /mnt/p
		fi
	else
		note "!! rw mount failed: $(tail -1 $out/$n.err)"
	fi
	dmesg -c > $out/$n.rw.dmesg
	[ -s $out/$n.rw.dmesg ] && sed -n '1,8p' $out/$n.rw.dmesg | sed 's/^/    dmesg: /' | tee -a $sum
	losetup -d $loop
	cp --sparse=always $work/$n.img $out/$n.img
	cp $in/$n.manifest $out/$n.manifest
	rm -f $work/$n.img
done

# --- NTFS -------------------------------------------------------------------
# ドライバごとに同じことをする: Windows が作ったものを ro で読み、そこへ
# 書き足し、自分で mkntfs したものへも書く。出来たイメージは Windows の
# chkdsk にかける (win-check.ps1)。
nmount() {	# driver dev [ro]
	case $1 in
	ntfs-3g) ntfs-3g ${3:+-o ro} $2 /mnt/p ;;
	*)       mount -t $1 ${3:+-o ro} $2 /mnt/p ;;
	esac
}
note ""
note "## NTFS (ntfs-3g $(rpm -q --qf '%{VERSION}' ntfs-3g))"
for drv in $drivers; do
	w=win-ntfs-$drv
	a=alma-ntfs-$drv
	if [ -e $in/win-ntfs.vhd ]; then
		note ""
		note "### $w (made by Windows, driver $drv)"
		cp --sparse=always $in/win-ntfs.vhd $work/$w.vhd
		loop=$(losetup -f -P --show $work/$w.vhd)
		if nmount $drv ${loop}p1 ro 2>>$out/$w.err; then
			mani /mnt/p/src 2>$out/$w.mani.err | grep '^H|' > $out/$w.alma-ro.H
			LC_ALL=C sort $in/win-ntfs.manifest | tr -d '\r' > $work/w.H
			diff $work/w.H $out/$w.alma-ro.H > $out/$w.ro.diff
			note "ro: H lines Windows $(wc -l < $work/w.H), Linux $(wc -l < $out/$w.alma-ro.H), differing $(grep -c '^[<>]' $out/$w.ro.diff)"
			sed -n '1,12p' $out/$w.ro.diff | tee -a $sum
			note "ro: manifest errors: $(wc -l < $out/$w.mani.err)"
			sed -n '1,6p' $out/$w.mani.err | tee -a $sum
			ls -la /mnt/p/src > $out/$w.ls 2>&1
			grep -E 'sym_|junction|ads|lz|sparse' $out/$w.ls | tee -a $sum
			getfattr -d -m - /mnt/p/src/ads.txt 2>&1 | tee -a $sum
			note "sparse: apparent $(du -k --apparent-size /mnt/p/src/sparse5g | cut -f1)k, allocated $(du -k /mnt/p/src/sparse5g | cut -f1)k"
			umount /mnt/p
		else
			note "!! ro mount failed: $(tail -1 $out/$w.err)"
		fi
		dmesg -c > $out/$w.ro.dmesg
		if nmount $drv ${loop}p1 2>>$out/$w.err; then
			note "rw: $(awk '$2 == "/mnt/p" { print $3, $4 }' /proc/mounts)"
			sh $here/mktree.sh /mnt/p/linux > $out/$w.mktree 2>&1
			note "rw: mktree exit $? $(head -3 $out/$w.mktree | tr '\n' ' ')"
			mani /mnt/p/linux > $out/$w.linux.manifest 2>>$out/$w.err
			umount /mnt/p
			ntfsfix -n ${loop}p1 > $out/$w.ntfsfix 2>&1
			note "rw: ntfsfix -n exit $?"
		else
			note "!! rw mount failed: $(tail -1 $out/$w.err)"
		fi
		dmesg -c > $out/$w.rw.dmesg
		[ -s $out/$w.rw.dmesg ] && grep -v drop_caches $out/$w.rw.dmesg | sed -n '1,8p' | sed 's/^/    dmesg: /' | tee -a $sum
		losetup -d $loop
		cp --sparse=always $work/$w.vhd $out/$w.vhd
		rm -f $work/$w.vhd
	fi

	note ""
	note "### $a (mkntfs on Alma, driver $drv)"
	truncate -s 512M $work/$a.raw
	echo 'type=7' | sfdisk -q $work/$a.raw
	loop=$(losetup -f -P --show $work/$a.raw)
	mkntfs -Q -L ALMA ${loop}p1 > $out/$a.mkntfs 2>&1
	if nmount $drv ${loop}p1 2>>$out/$a.err; then
		note "rw: $(awk '$2 == "/mnt/p" { print $3, $4 }' /proc/mounts)"
		sh $here/mktree.sh /mnt/p/linux > $out/$a.mktree 2>&1
		note "mktree exit $? $(head -3 $out/$a.mktree | tr '\n' ' ')"
		mani /mnt/p/linux > $out/$a.linux.manifest
		umount /mnt/p
		drop
		nmount $drv ${loop}p1 ro
		mani /mnt/p/linux > $out/$a.linux.reread
		note "after remount, differing lines $(ndiff $out/$a.linux.manifest $out/$a.linux.reread)"
		umount /mnt/p
		ntfsfix -n ${loop}p1 > $out/$a.ntfsfix 2>&1
		note "ntfsfix -n exit $?"
	else
		note "!! rw mount failed: $(tail -1 $out/$a.err)"
	fi
	dmesg -c > $out/$a.dmesg
	[ -s $out/$a.dmesg ] && grep -v drop_caches $out/$a.dmesg | sed -n '1,8p' | sed 's/^/    dmesg: /' | tee -a $sum
	losetup -d $loop
	qemu-img convert -f raw -O vpc -o subformat=fixed,force_size=on \
		$work/$a.raw $out/$a.vhd
	rm -f $work/$a.raw
done
cp $in/win-ntfs.manifest $out/win-ntfs.manifest 2>/dev/null

# 物差し: 同じ VM、同じ loop で xfs
note ""
truncate -s 512M $work/xfs.raw
loop=$(losetup -f --show $work/xfs.raw)
mkfs.xfs -q $loop && mount $loop /mnt/p && {
	sh $here/mktree.sh /mnt/p/linux > $out/xfs.mktree 2>&1
	mani /mnt/p/linux > $out/xfs.linux.manifest
	bench "xfs (reference)" /mnt/p
	umount /mnt/p
}
losetup -d $loop

# どの fs で何が落ちるかの物差しとして、xfs で取った manifest との差を並べる。
# mktree の中身は回ごとに乱数なので H 行は比べず、mtime も touch -t で
# 決めた t2000/t2040 のほかは伏せる。
norm() {
	awk -F'|' 'BEGIN{OFS="|"}
		$1 == "M" { if ($8 !~ /t20[04]0$/) $5 = "*"; print }
		$1 == "L" { print }' "$1" | grep -v '/many/' | LC_ALL=C sort
}
note ""
note "## Linux が書いた metadata の xfs との差"
norm $out/xfs.linux.manifest > $work/xfs.norm
for m in $out/*.linux.manifest; do
	n=$(basename $m .linux.manifest)
	[ $n = xfs ] && continue
	norm $m > $work/$n.norm
	diff $work/xfs.norm $work/$n.norm | grep '^[<>]' > $out/$n.vs-xfs
	note "$n: $(wc -l < $out/$n.vs-xfs) differing lines vs xfs"
	grep '^<' $out/$n.vs-xfs | sed -n '1,12p' | sed 's/^/    /' | tee -a $sum
	grep '^>' $out/$n.vs-xfs | sed -n '1,12p' | sed 's/^/    /' | tee -a $sum
done
dmesg > $out/dmesg-end.txt
ls -ls $out
