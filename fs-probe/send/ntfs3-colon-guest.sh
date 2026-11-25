#!/bin/sh
# ntfs3 の ':' (symlink の先、label、ADS) と、Windows の絶対 symlink を見る。
#   ntfs3-colon-guest.sh <in> <out> <label>
in=$1 out=$2 label=$3
here=$(dirname $0)
w=/run/w
mkdir -p $out $w && mount -t tmpfs -o size=2g none $w && mkdir $w/m
sum=$out/$label.txt; : > $sum
note() { printf '%s\n' "$*" | tee -a $sum; }
note "# $label kernel $(uname -r) $(uname -v)"
dmesg -C
nm() {	# dev [opts]。種別まで確かめる。無い option は 1 を返すだけ
	mount -i -t ntfs3 ${2:+-o $2} $1 $w/m 2> $w/mnt.err && [ "$(awk -v m=$w/m '$2 == m { print $3 }' /proc/mounts | tail -1)" = ntfs3 ]
}
must() { nm "$@" || { note "!! mount of $1 ($2) failed: $(cat $w/mnt.err)"; exit 1; }; }
mk() {	# name size
	truncate -s $2 $w/$1.raw; echo 'type=7' | sfdisk -q $w/$1.raw
	l=$(losetup -f -P --show $w/$1.raw); mkntfs -Q -q -L T ${l}p1 > /dev/null 2>&1
}
rd() { python3 -I -c 'import sys; print(repr(open(sys.argv[1], "rb").read())[1:])' "$1" 2>&1; }

# --- symlink の先が書いたとおりに返るか。mount option ごとに新しい volume で。
for cfg in default ads=0 iocharset=iso8859-1 iocharset=utf8 nocase native_symlink=rel native_symlink=raw; do
	mk rt 64M
	o=$cfg; [ $cfg = default ] && o=
	if ! nm ${l}p1 $o; then
		note "links $cfg: mount refused ($(dmesg | grep -i ntfs3 | tail -1 | sed 's/^[^]]*] //'))"
		losetup -d $l; rm -f "${w:?}"/rt.raw; continue
	fi
	note "mount options: $(awk -v m=$w/m '$2 == m { print $4 }' /proc/mounts | tail -1)"
	mkdir $w/m/sub
	la=; [ $cfg = iocharset=iso8859-1 ] && la=latin1
	note "$(python3 -I $here/ntfs3-colon-links.py make $w/m/sub "$cfg cached" $la)"
	umount $w/m; must ${l}p1 $o
	note "$(python3 -I $here/ntfs3-colon-links.py check $w/m/sub "$cfg remount" $la)"
	if [ $cfg != default ] && [ $cfg != iocharset=iso8859-1 ]; then
		umount $w/m; must ${l}p1
		note "$(python3 -I $here/ntfs3-colon-links.py check $w/m/sub "$cfg read back with default options" $la)"
	fi
	umount $w/m; losetup -d $l; rm -f "${w:?}"/rt.raw
done

# --- ADS が前と同じに動くか。symlink が stream を指せるか。
mk ads 64M
must ${l}p1
cd $w/m
echo main > f
(echo one > f:s1) 2> $w/e; r1=$?
(echo two > f:s2) 2>> $w/e; r2=$?
note "ads create: rc $r1 $r2; f='$(cat f)' f:s1='$(cat f:s1 2>&1)' f:s2='$(cat f:s2 2>&1)'"
note "ads query_streams: $(cat f:query_streams 2>&1 | tr '\n' ' ')"
ln -s f:s1 to_stream; ln -s f to_file
note "ads symlink to f:s1 reads '$(cat to_stream 2>&1)', readlink '$(readlink to_stream)'; symlink to f reads '$(cat to_file 2>&1)'"
rm f:s2; note "ads rm f:s2: rc $?; query_streams: $(cat f:query_streams 2>&1 | tr '\n' ' '); f:s2 -> $(cat f:s2 2>&1 | sed 's/.*: //')"
(echo x > new:s) 2> $w/e; note "ads file and stream in one call: rc $?; new exists: $([ -e new ] && echo yes || echo no)"
dd if=/dev/urandom of=$w/big bs=1k count=300 status=none; cp $w/big f:big 2> $w/e; note "ads 300K stream: cp rc $?; same: $(cmp -s $w/big f:big && echo yes || echo no)"
cd /; umount $w/m; must ${l}p1; cd $w/m
note "ads after remount: f='$(cat f)' f:s1='$(cat f:s1 2>&1)' query_streams: $(cat f:query_streams 2>&1 | tr '\n' ' '); big same: $(cmp -s $w/big f:big && echo yes || echo no); symlink to f:s1 reads '$(cat to_stream 2>&1)'"
# 名前に ':' が要る操作 (rename、link)。直す対象ではなく、現状の記録。
echo x > p1; mv p1 q:r 2> $w/e; rc=$?; note "probe mv p1 q:r: rc $rc ($(sed 's/.*: //' $w/e | head -1)); names: $(ls | tr '\n' ' ')"
echo x > p2; ln p2 h:k 2> $w/e; rc=$?; note "probe ln p2 h:k: rc $rc ($(sed 's/.*: //' $w/e | head -1)); names: $(ls | tr '\n' ' ')"
ln -s x sl:1 2> $w/e; note "probe ln -s x sl:1: rc $? ($(sed 's/.*: //' $w/e | head -1))"
cd /; umount $w/m
# nocase では d_hash と d_compare も名前を ':' で切る
must ${l}p1 nocase; cd $w/m
echo main > g; (printf 'E1' > 'g:é') 2> /dev/null; (printf 'E2' > 'g:è') 2> /dev/null
note "probe nocase streams: g:é='$(cat 'g:é' 2>&1)' g:è='$(cat 'g:è' 2>&1)' query_streams: $(cat g:query_streams 2>&1 | tr '\n' ' ')"
cd /; umount $w/m
# ads=0 では ':' は名前の一文字
must ${l}p1 ads=0; cd $w/m
(echo colonfile > n:m) 2> $w/e; rc=$?; ln -s n:m to_colon
note "ads=0: create n:m rc $rc; symlink to n:m reads '$(cat to_colon 2>&1)', readlink '$(readlink to_colon)'; f:s1 -> $(cat f:s1 2>&1 | sed 's/.*: //')"
cd /; umount $w/m; losetup -d $l; rm -f "${w:?}"/ads.raw

# --- label
mk lab 64M
for cfg in default ads=0; do
	o=$cfg; [ $cfg = default ] && o=
	must ${l}p1 $o
	lp=/proc/fs/ntfs3/$(basename ${l}p1)/label
	lab() {	# 書く label。cached、remount 後、ntfs-3g が disk から読んだもの
		printf '%s' "$1" > $lp 2> $w/e; rc=$?
		c=$(rd $lp)
		umount $w/m; raw=$(ntfslabel ${l}p1 2> /dev/null | od -An -c | tr -s ' ' | tr -d '\n'); must ${l}p1 $o
		s=$1; [ ${#s} -gt 40 ] && s="$(printf '%s' "$1" | cut -c1-8)...(${#s})"
		note "label $cfg '$s': write rc $rc; cached $c; remount $(rd $lp); ntfslabel$raw"
	}
	lab plain; lab a:b; lab ab:; lab :ab; lab a:b:c; lab '日本:語'
	lab 'L234567890123456789012345678:Z'
	lab "$(printf '%0300d' 0 | tr 0 a)"
	lab "$(printf '%0260d' 0 | tr 0 a):b"
	python3 -I -c '
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    fcntl.ioctl(fd, 0x41009432, b"x:y".ljust(256, b"\0")); r = "ok"
except OSError as e:
    r = e.strerror
b = bytearray(256); fcntl.ioctl(fd, 0x81009431, b)
print("label %s FS_IOC_SETFSLABEL x:y: %s; FS_IOC_GETFSLABEL %r" % (sys.argv[2], r, bytes(b).rstrip(b"\0")))' $w/m $cfg > $w/io 2>&1; note "$(cat $w/io)"
	umount $w/m; raw=$(ntfslabel ${l}p1 2> /dev/null | od -An -c | tr -s ' ' | tr -d '\n'); must ${l}p1 $o
	note "label $cfg after the ioctl and remount: $(rd $lp); ntfslabel$raw"
	umount $w/m
done
losetup -d $l; rm -f "${w:?}"/lab.raw

# --- Windows が作った junction と symlink
cp --sparse=always $in/win-ntfs.vhd $w/win.vhd
l=$(losetup -f -P --show $w/win.vhd)
for p in ${l}p1 ${l}p2; do [ -b $p ] && [ "$(blkid -o value -s TYPE $p)" = ntfs ] && part=$p; done
for cfg in default native_symlink=rel; do
	o=ro; [ $cfg = default ] || o=ro,$cfg
	if nm $part $o; then
		for r in junction sym_dir sym_file sym_rel; do
			note "win $cfg $r -> '$(readlink $w/m/src/$r 2>&1)' follows: $(stat -L -c %F $w/m/src/$r 2>&1 | sed 's/.*: //')"
		done
		umount $w/m
	else note "win $cfg: mount refused"; fi
done
losetup -d $l; rm -f "${w:?}"/win.vhd

# --- Windows に読ませる symlink。C:\Windows は runner に在る。
mk links 64M
must ${l}p1
mkdir $w/m/links $w/m/links/sub; cd $w/m/links
echo data > data.txt; echo subdata > sub/data.txt
ln -s 'C:/Windows/System32/drivers/etc/hosts' abs_file
ln -s 'C:\Windows\System32\drivers\etc\hosts' abs_file_bs
ln -s 'C:/Windows' abs_dir
ln -s data.txt rel_file
ln -s sub/data.txt rel_sub
ln -s ../links/data.txt rel_up
ln -s sub rel_dir
ln -s C:data.txt drive_rel
for n in abs_file abs_file_bs abs_dir rel_file rel_sub rel_up rel_dir drive_rel; do note "links readlink $n -> '$(readlink $n)'"; done
cd /; umount $w/m
for n in abs_file abs_file_bs abs_dir rel_file rel_sub rel_up rel_dir drive_rel; do
	note "links on disk $n: $(ntfscat -a 0xc0 ${l}p1 links/$n 2> $w/e | python3 -I -c '
import struct, sys
d = sys.stdin.buffer.read()
if len(d) < 20: print("no reparse data (%d bytes)" % len(d)); sys.exit()
tag, dl = struct.unpack_from("<IH", d, 0)
so, sl, po, pl, fl = struct.unpack_from("<HHHHI", d, 8)
pb = d[20:]
print("tag %#x flags %d substitute %r print %r" % (tag, fl, pb[so:so + sl].decode("utf-16le", "replace"), pb[po:po + pl].decode("utf-16le", "replace")))' 2>&1) $(head -1 $w/e)"
done
losetup -d $l
qemu-img convert -f raw -O vpc -o subformat=fixed,force_size=on $w/links.raw $w/out.vhd && gzip -1 -c $w/out.vhd > $out/$label-links.vhd.gz
rm -f "${w:?}"/links.raw "${w:?}"/out.vhd

note "dmesg: $(dmesg | grep -E 'WARNING|BUG|KASAN|UBSAN|Oops|general protection' | head -6 | tr '\n' ';')"
dmesg | grep -i ntfs3 | sed 's/^[^]]*] //' | sort | uniq -c | sort -rn | head -12 > $out/$label-dmesg.txt
note END
