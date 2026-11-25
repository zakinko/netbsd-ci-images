#!/bin/sh
# mainline の ntfs3 と ntfs の、当て物が直す所だけを見る。
#   ntfs-guest.sh <in> <out> <label> <fsstress> <ntfs3|ntfs>
in=$1 out=$2 label=$3 fss=$4 drv=$5
w=/run/w
mkdir -p $out $w && mount -t tmpfs -o size=7g none $w && mkdir $w/m
sum=$out/$label.txt; : > $sum
note() { printf '%s\n' "$*" | tee -a $sum; }
note "# $label kernel $(uname -r) $(uname -v)"
dmesg -C
nm() {	# dev [opts]。種別まで確かめる
	mount -i -t $drv ${2:+-o $2} $1 $w/m && [ "$(awk -v m=$w/m '$2 == m { print $3 }' /proc/mounts | tail -1)" = $drv ] || { note "!! mount of $1 as $drv failed"; exit 1; }
}
mk() {	# name size
	truncate -s $2 $w/$1.raw; echo 'type=7' | sfdisk -q $w/$1.raw
	l=$(losetup -f -P --show $w/$1.raw); mkntfs -Q -q -L T ${l}p1 > /dev/null 2>&1
}
if [ $drv = ntfs3 ]; then
# --- Windows が作った junction と symlink (ntfs3-01a/b)
cp --sparse=always $in/win-ntfs.vhd $w/win.vhd
l=$(losetup -f -P --show $w/win.vhd)
for p in ${l}p1 ${l}p2; do [ -b $p ] && [ "$(blkid -o value -s TYPE $p)" = ntfs ] && part=$p; done
nm $part ro
if :; then
	for r in junction sym_dir sym_file sym_rel; do
		note "win $r -> '$(readlink $w/m/src/$r 2>&1)' follows: $(stat -L -c %F $w/m/src/$r 2>&1 | sed 's/.*: //')"
	done
	umount $w/m
else note "!! win mount failed"; fi
losetup -d $l; rm -f "${w:?}"/win.vhd
# --- Linux で作った symlink が書いたとおりに返るか (ntfs3-01b)
mk rt 64M
nm ${l}p1
mkdir $w/m/x $w/m/sub; i=0
for t in a:b C: C:x C:/x 'C:\x' 1:/x /abs/x rel/x x; do i=$((i + 1)); ln -s "$t" $w/m/sub/r$i; note "rt cached '$t' -> '$(readlink $w/m/sub/r$i)'"; done
umount $w/m; nm ${l}p1; i=0
for t in a:b C: C:x C:/x 'C:\x' 1:/x /abs/x rel/x x; do i=$((i + 1)); note "rt remount '$t' -> '$(readlink $w/m/sub/r$i)' follows: $(stat -L -c %F $w/m/sub/r$i 2>&1 | sed 's/.*: //')"; done
umount $w/m; losetup -d $l; rm -f "${w:?}"/rt.raw
# --- 長い symlink の d_type (ntfs3-02)
mk sym 256M
nm ${l}p1
for n in 10 100 200 500 1000; do ln -s $(printf "%0${n}d" 0 | tr 0 a) $w/m/s$n; done
ty() { python3 -c '
import os,sys
print(" ".join(sorted("%s=%s" % (e.name, "lnk" if e.is_symlink() else "reg" if e.is_file(follow_symlinks=False) else "?") for e in os.scandir(sys.argv[1]) if e.name.startswith("s"))))' $w/m; }
note "sym d_type cached: $(ty)"
umount $w/m; nm ${l}p1
note "sym d_type after remount: $(ty); lstat: $(stat -c '%n=%F' $w/m/s* | sed "s,$w/m/,,g" | tr '\n' ' ')"
# 作った後に時刻、持ち主、hard link を変えると、親の $I30 の複製が書き直される
touch -h -d 2020-01-02 $w/m/s*; sync
umount $w/m; nm ${l}p1; note "sym d_type after touch -h and remount: $(ty)"
chown -h 1:1 $w/m/s*; sync
umount $w/m; nm ${l}p1; note "sym d_type after chown -h and remount: $(ty)"
for n in 10 200 1000; do mv $w/m/s$n $w/m/sr$n; done; sync
umount $w/m; nm ${l}p1; note "sym d_type after rename and remount: $(ty)"
umount $w/m; losetup -d $l; rm -f "${w:?}"/sym.raw
# --- 0 に縮めたファイル (ntfs3-03)。断片化したものと、伸ばし直すものも。
mk trunc 512M
nm ${l}p1
bad=0
for i in $(seq 1 60); do
	dd if=/dev/urandom of=$w/m/t$i bs=64k count=$((i % 9 + 1)) status=none || bad=$((bad + 1))
	sync $w/m/t$i
done
for i in $(seq 1 2 60); do truncate -s 0 $w/m/t$i || bad=$((bad + 1)); done
sync
for i in $(seq 1 4 60); do echo "again $i" > $w/m/t$i || bad=$((bad + 1)); done
dd if=/dev/urandom of=$w/m/frag bs=4k count=2000 oflag=dsync status=none & dd if=/dev/urandom of=$w/m/frag2 bs=4k count=2000 oflag=dsync status=none; wait
truncate -s 0 $w/m/frag || bad=$((bad + 1))
note "truncate errors: $bad; sizes wrong: $(for i in $(seq 1 60); do s=$(stat -c %s $w/m/t$i); if [ $((i % 2)) = 0 ]; then e=$(((i % 9 + 1) * 65536)); elif [ $((i % 4)) = 1 ]; then e=$(printf 'again %s\n' $i | wc -c); else e=0; fi; [ $s = $e ] || echo $i; done | wc -l)"
(cd $w/m && sha256sum t* | sort) > $w/h1
(cd $w/m && find . -xdev -printf '%i %y %s %p\n') > $out/$label-trunc.inodes
umount $w/m; nm ${l}p1
(cd $w/m && sha256sum t* | sort) > $w/h2
note "trunc: differing after remount $(diff $w/h1 $w/h2 | grep -c '^[<>]') of $(wc -l < $w/h1)"
umount $w/m
awk '$2 == "f" && $3 == 0 { print $1 }' $out/$label-trunc.inodes > $w/z
note "trunc: empty \$DATA with runs left: $(python3 -I $(dirname $0)/../mftattr.py ${l}p1 $(cat $w/z) | grep -c STALE-RUNS) of $(wc -l < $w/z)"
losetup -d $l
qemu-img convert -f raw -O vpc -o subformat=fixed,force_size=on $w/trunc.raw $w/out.vhd && gzip -1 -c $w/out.vhd > $out/$label-trunc.vhd.gz
rm -f "${w:?}"/trunc.raw "${w:?}"/out.vhd
# --- fsstress
mk fss 2G
nm ${l}p1
timeout 900 $fss -d $w/m/fss -n 4000 -p 4 -s 1 > $w/fss.log 2>&1
note "fsstress exit $?"
sync
(cd $w/m && find . -xdev -printf '%i %y %s %p\n') > $out/$label-fss.inodes
(cd $w/m && find . -type f -print0 | sort -z | xargs -0 -r sha256sum) > $w/h1 2>/dev/null
umount $w/m; nm ${l}p1; (cd $w/m && find . -type f -print0 | sort -z | xargs -0 -r sha256sum) > $w/h2 2>/dev/null
note "fss: differing after remount $(diff $w/h1 $w/h2 | grep -c '^[<>]') of $(wc -l < $w/h1)"
umount $w/m
awk '$2 == "f" && $3 == 0 { print $1 }' $out/$label-fss.inodes > $w/z
note "fss: empty \$DATA with runs left: $(python3 -I $(dirname $0)/../mftattr.py ${l}p1 $(cat $w/z) | grep -c STALE-RUNS) of $(wc -l < $w/z)"
losetup -d $l
qemu-img convert -f raw -O vpc -o subformat=fixed,force_size=on $w/fss.raw $w/out.vhd && gzip -1 -c $w/out.vhd > $out/$label-fss.vhd.gz
rm -f "${w:?}"/fss.raw "${w:?}"/out.vhd
else
# --- fs/ntfs のディレクトリの大きさ (ntfs-01)
mk dir 256M
nm ${l}p1
if :; then
	sz() { (cd $w/m && stat -c '%n=%s' new full g* | tr '\n' ' '); }
	mkdir $w/m/new $w/m/full; for i in $(seq 1 300); do : > $w/m/full/f$i; done
	for i in 1 2 3 4 5 6 7 8 9 10 11 12; do mkdir $w/m/g$i; for j in $(seq 1 $i); do : > $w/m/g$i/file$j; done; done
	note "dir size before umount: $(sz)"; umount $w/m; nm ${l}p1; note "dir size after remount: $(sz)"
	umount $w/m
else note "!! ntfs mount failed"; fi
losetup -d $l
fi
note "dmesg: $(dmesg | grep -iE 'ntfs|WARNING|BUG|KASAN' | head -6 | tr '\n' ';')"
note END
