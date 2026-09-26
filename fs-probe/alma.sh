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

rel=$(echo $KV | sed -n 's/.*\.el10_\([0-9]*\)\..*/10.\1/p')
v=${KV%.x86_64}
if ! dnf -y -q install kernel-devel-$KV; then
	for u in https://vault.almalinux.org/$rel/AppStream/x86_64/os/Packages \
	         https://repo.almalinux.org/almalinux/$rel/AppStream/x86_64/os/Packages; do
		rpm -ivh --nodeps $u/kernel-devel-$v.x86_64.rpm && break
	done
fi
cd $work
for u in https://vault.almalinux.org/$rel/BaseOS/Source/Packages \
         https://repo.almalinux.org/almalinux/$rel/BaseOS/Source/Packages; do
	curl -fsSL -o k.src.rpm $u/kernel-$v.src.rpm && break
done
rpm2cpio k.src.rpm | cpio -idm --quiet 'linux-*.tar.xz'
tar -xJf linux-*.tar.xz --wildcards '*/fs/ufs/*' '*/Documentation/admin-guide/ufs.rst'
ufsdir=$(echo $work/linux-*/fs/ufs)
note "ufs source: $ufsdir"
# UFS_FS_WRITE は C の #ifdef で見られるだけなので、-D で渡せば足りる。
make -C /lib/modules/$KV/build M=$ufsdir CONFIG_UFS_FS=m \
	KCFLAGS=-DCONFIG_UFS_FS_WRITE=1 modules > $out/ufs-build.log 2>&1
note "ufs build exit $? ($(grep -c warning: $out/ufs-build.log) warnings)"
insmod $ufsdir/ufs.ko && note "ufs.ko loaded" || note "!! insmod ufs.ko failed"
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
note ""
note "## NTFS (ntfs-3g $(rpm -q --qf '%{VERSION}' ntfs-3g))"

# Windows が作ったもの
if [ -e $in/win-ntfs.vhd ]; then
	note ""
	note "### win-ntfs (made by Windows)"
	cp --sparse=always $in/win-ntfs.vhd $work/win-ntfs.vhd
	loop=$(losetup -f -P --show $work/win-ntfs.vhd)
	if ntfs-3g -o ro ${loop}p1 /mnt/p 2>>$out/win-ntfs.err; then
		mani /mnt/p/src 2>$out/win-ntfs.mani.err | grep '^H|' > $out/win-ntfs.alma-ro.H
		LC_ALL=C sort $in/win-ntfs.manifest | tr -d '\r' > $work/w.H
		diff $work/w.H $out/win-ntfs.alma-ro.H > $out/win-ntfs.ro.diff
		note "ro: H lines Windows $(wc -l < $work/w.H), Linux $(wc -l < $out/win-ntfs.alma-ro.H), differing $(grep -c '^[<>]' $out/win-ntfs.ro.diff)"
		sed -n '1,12p' $out/win-ntfs.ro.diff | tee -a $sum
		note "ro: manifest errors: $(wc -l < $out/win-ntfs.mani.err)"
		sed -n '1,6p' $out/win-ntfs.mani.err | tee -a $sum
		ls -la /mnt/p/src > $out/win-ntfs.ls 2>&1
		grep -E 'sym_|junction|ads|lz|sparse' $out/win-ntfs.ls | tee -a $sum
		getfattr -d -m - /mnt/p/src/ads.txt 2>&1 | tee -a $sum
		note "ads stream: $(cat /mnt/p/src/ads.txt:secret 2>&1 || true)"
		du -k --apparent-size /mnt/p/src/sparse5g | tee -a $sum
		du -k /mnt/p/src/sparse5g | tee -a $sum
		umount /mnt/p
	else
		note "!! ro mount failed: $(tail -1 $out/win-ntfs.err)"
	fi
	if ntfs-3g ${loop}p1 /mnt/p 2>>$out/win-ntfs.err; then
		note "rw: $(awk '$2 == "/mnt/p" { print $3, $4 }' /proc/mounts)"
		sh $here/mktree.sh /mnt/p/linux > $out/win-ntfs.mktree 2>&1
		note "rw: mktree exit $? $(head -3 $out/win-ntfs.mktree | tr '\n' ' ')"
		mani /mnt/p/linux > $out/win-ntfs.linux.manifest 2>>$out/win-ntfs.err
		umount /mnt/p
		ntfsfix -n ${loop}p1 > $out/win-ntfs.ntfsfix 2>&1
		note "rw: ntfsfix -n exit $?"
	fi
	losetup -d $loop
	cp --sparse=always $work/win-ntfs.vhd $out/win-ntfs.vhd
	cp $in/win-ntfs.manifest $out/win-ntfs.manifest
fi

# Linux が作ったもの
note ""
note "### alma-ntfs (mkntfs on Alma)"
truncate -s 512M $work/alma-ntfs.raw
echo 'type=7' | sfdisk -q $work/alma-ntfs.raw
loop=$(losetup -f -P --show $work/alma-ntfs.raw)
mkntfs -Q -L ALMA ${loop}p1 > $out/alma-ntfs.mkntfs 2>&1
ntfs-3g ${loop}p1 /mnt/p
sh $here/mktree.sh /mnt/p/linux > $out/alma-ntfs.mktree 2>&1
note "mktree exit $? $(head -3 $out/alma-ntfs.mktree | tr '\n' ' ')"
mani /mnt/p/linux > $out/alma-ntfs.linux.manifest
bench "ntfs-3g" /mnt/p
umount /mnt/p
drop
ntfs-3g -o ro ${loop}p1 /mnt/p
mani /mnt/p/linux > $out/alma-ntfs.linux.reread
note "after remount, differing lines $(ndiff $out/alma-ntfs.linux.manifest $out/alma-ntfs.linux.reread)"
umount /mnt/p
ntfsfix -n ${loop}p1 > $out/alma-ntfs.ntfsfix 2>&1
note "ntfsfix -n exit $?"
losetup -d $loop
qemu-img convert -f raw -O vpc -o subformat=fixed,force_size=on \
	$work/alma-ntfs.raw $out/alma-ntfs.vhd

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
