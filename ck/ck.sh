#!/bin/sh
# Runs as root inside the chroot of the patched sets, on the patched
# kernel: ck.sh <dir with plain.img.xz eaonly.img.xz>
# Exercises the FreeBSD metadata check-hashes: keeping them through
# writes (with and without WAPBL), catching damage to each kind, fsck
# repairing it, tunefs, a NetBSD file system given check-hashes by
# fsck, quota2 left alone, and the cost of keeping them.
# Images for FreeBSD to verify are left in $W/out with a .sums manifest.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
P=$1
W=/tmp/ck
M=$W/m
rm -rf $W; mkdir -p $M $W/out; cd $W || exit 1

SB=65536			# UFS2 superblock
get32() { od -An -tu4 -j $2 -N4 $1 | tr -d ' '; }
put32() {	# img off value
	v=$3
	printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $((v & 255)) \
	    $((v >> 8 & 255)) $((v >> 16 & 255)) $((v >> 24 & 255)))" |
	    dd of=$1 bs=1 seek=$2 conv=notrunc 2>/dev/null
}
flip() {	# img off: invert one byte
	b=$(od -An -tu1 -j $2 -N1 $1 | tr -d ' ')
	printf "$(printf '\\%03o' $((b ^ 255)))" |
	    dd of=$1 bs=1 seek=$2 conv=notrunc 2>/dev/null
}
sbinfo() {	# img
	printf '  flags=%#x metackhash=%#x ckhash=%#x quota_magic=%#x\n' \
	    $(get32 $1 $((SB + 1312))) $(get32 $1 $((SB + 1308))) \
	    $(get32 $1 $((SB + 1304))) $(get32 $1 $((SB + 904)))
}
on() {	# img [mount options]: attach and mount, report
	i=$1; shift
	vnconfig vnd3 $i || return 1
	mount -t ffs "$@" /dev/vnd3a $M; r=$?
	echo "  mount $* $i -> rc=$r"
	[ $r = 0 ] || { dmesg | tail -2 | sed 's/^/  dmesg: /'; vnconfig -u vnd3; }
	return $r
}
off() { umount $M; r=$?; vnconfig -u vnd3; [ $r = 0 ] || echo "  umount rc=$r"; }
sums() {	# img: record what FreeBSD should find
	(cd $M && find . -type f ! -path './.snap/*' | LC_ALL=C sort | xargs sha256) \
	    > $W/out/${1%.img}.sums
	echo "  $(wc -l < $W/out/${1%.img}.sums) files recorded"
}
fsckn() {	# img: fsck -f -n, the lines that matter
	fsck_ffs -f -n $1 2>&1 | grep -vE '^\*\* (/|Last|Phase|File sys)|NO WRITE' |
	    sed 's/^/  fsck: /'
}
work() {	# a mixed workload on the mounted file system
	mkdir -p $M/w/a $M/w/b
	n=0
	while [ $n -lt 300 ]; do
		echo "file $n" > $M/w/a/s$n
		[ $((n % 10)) = 0 ] &&
		    dd if=/dev/urandom of=$M/w/b/m$n bs=4k count=$((n % 7 + 1)) 2>/dev/null
		n=$((n + 1))
	done
	dd if=/dev/urandom of=$M/w/big bs=64k count=64 2>/dev/null
	n=0
	while [ $n -lt 300 ]; do
		case $((n % 3)) in
		0) rm $M/w/a/s$n ;;
		1) mv $M/w/a/s$n $M/w/b/r$n ;;
		2) chmod 600 $M/w/a/s$n; touch $M/w/a/s$n ;;
		esac
		n=$((n + 1))
	done
	ln -s ../big $M/w/a/link
	mkdir $M/w/c && rmdir $M/w/c
	dd if=/dev/zero of=$M/w/fill bs=64k count=200 2>/dev/null
	rm $M/w/fill
	sync
}

echo "=== ck: $(uname -v)"
xz -dc $P/plain.img.xz > plain.img
xz -dc $P/eaonly.img.xz > eaonly.img

echo "[fsck-fbsd] patched fsck_ffs -f -n on the FreeBSD images as made"
for i in plain eaonly; do
	echo " $i:"; sbinfo $i.img; fsckn $i.img
done

echo "[ro] eaonly read-only, every file read"
if on eaonly.img -r; then
	for f in $M/f*; do cat $f > /dev/null || echo "  read $f failed"; done
	echo "  read $(ls $M | wc -l) entries"; off
fi

echo "[rw] eaonly copy, mixed workload, no log"
cp eaonly.img rw.img
if on rw.img; then
	rm $M/f3; work; sums rw.img; off
fi
sbinfo rw.img; fsckn rw.img; cp rw.img out/

echo "[log] plain copy, workload with -o log, then a mount without log"
cp plain.img log.img
if on log.img -o log; then work; off; fi
sbinfo log.img
if on log.img; then sums log.img; off; fi
sbinfo log.img; fsckn log.img; cp log.img out/

# Offsets for the damage below.
fsize=$(get32 eaonly.img $((SB + 52)))
cblkno=$(get32 eaonly.img $((SB + 12)))
iblkno=$(get32 eaonly.img $((SB + 16)))
fpg=$(get32 eaonly.img $((SB + 188)))

echo "[bad-sb] one byte of fs_fsmnt changed"
cp eaonly.img badsb.img; flip badsb.img $((SB + 300))
on badsb.img -r && off
on badsb.img -r -o force && off
fsck_ffs -f -p badsb.img 2>&1 | sed 's/^/  fsck -f -p: /'
on badsb.img -r && off
sbinfo badsb.img; fsckn badsb.img; cp badsb.img out/

echo "[bad-cg] cg 2: its stored check-hash changed"
cp eaonly.img badcg.img; flip badcg.img $(((2 * fpg + cblkno) * fsize + 133))
if on badcg.img; then
	dd if=/dev/zero of=$M/fill bs=64k 2>/dev/null
	echo "  filled: $(ls -l $M/fill | awk '{print $5}') bytes"
	dmesg | grep 'bad check-hash' | tail -2 | sed 's/^/  dmesg: /'
	rm $M/fill; off
fi
fsck_ffs -f -p badcg.img 2>&1 | sed 's/^/  fsck -f -p: /'
fsckn badcg.img
if on badcg.img; then
	dd if=/dev/zero of=$M/fill bs=64k 2>/dev/null
	echo "  filled after fsck: $(ls -l $M/fill | awk '{print $5}') bytes"
	rm $M/fill; sums badcg.img; off
fi
cp badcg.img out/

echo "[bad-inode] inode 7 (f4): one reserved byte (di_spare) changed"
cp eaonly.img badino.img; flip badino.img $((iblkno * fsize + 7 * 256 + 250))
if on badino.img -r; then
	cat $M/f4 > /dev/null; echo "  cat f4 rc=$?"
	cat $M/f5 > /dev/null; echo "  cat f5 rc=$?"
	dmesg | grep 'bad check-hash' | tail -1 | sed 's/^/  dmesg: /'
	off
fi
fsck_ffs -f -p badino.img 2>&1 | sed 's/^/  fsck -f -p: /'
if on badino.img -r; then cat $M/f4 > /dev/null; echo "  cat f4 rc=$?"; off; fi
fsckn badino.img; cp badino.img out/

echo "[fsck-y] patched fsck_ffs -f -y on an eaonly copy"
cp eaonly.img fscky.img
fsck_ffs -f -y fscky.img 2>&1 | grep -vE '^\*\* (/|Last|Phase)' | sed 's/^/  fsck: /'
sbinfo fscky.img; cp fscky.img out/

echo "[tunefs] eaonly copy"
cp eaonly.img tune.img
tunefs -m 5 tune.img 2>&1 | sed 's/^/  /'
tunefs -q user tune.img 2>&1 | sed 's/^/  /'
tunefs -N tune.img 2>&1 | grep -E 'quotas|check-hashes|minimum' | sed 's/^/  /'
sbinfo tune.img
if on tune.img; then echo tuned > $M/tuned; sums tune.img; off; fi
fsckn tune.img; cp tune.img out/

echo "[nb] a NetBSD file system given check-hashes by fsck_ffs"
dd if=/dev/zero of=nb.img bs=1m count=64 2>/dev/null
newfs -F -s 64m -O2 nb.img > /dev/null
if on nb.img; then echo before > $M/before; mkdir $M/d; off; fi
put32 nb.img $((SB + 1308)) 7
put32 nb.img $((SB + 1312)) $(($(get32 nb.img $((SB + 1312))) | 512))
sbinfo nb.img
fsck_ffs -f -n nb.img 2>&1 | grep -c 'CHECK HASH' | sed 's/^/  fsck -n: check-hash complaints: /'
fsck_ffs -f -y nb.img 2>&1 | grep -E 'CHECK HASH|MODIFIED|files,' |
    sort | uniq -c | sed 's/^/  fsck -y: /'
fsckn nb.img
if on nb.img; then work; sums nb.img; off; fi
sbinfo nb.img; fsckn nb.img; cp nb.img out/

echo "[quota2] newfs -O2 -q user, untouched by all this"
dd if=/dev/zero of=q2.img bs=1m count=32 2>/dev/null
newfs -F -s 32m -O2 -q user q2.img > /dev/null
sbinfo q2.img
if on q2.img; then echo q > $M/q; repquota -u $M | sed -n 3,4p | sed 's/^/  /'; off; fi
fsckn q2.img

echo "[cost] 1 GB, 32k/4k, same file system with and without check-hashes"
dd if=/dev/zero of=pa.img bs=1m count=1 seek=1023 2>/dev/null
newfs -F -s 1g -O2 -b 32k -f 4k pa.img > /dev/null
cp pa.img pb.img
put32 pb.img $((SB + 1308)) 7
put32 pb.img $((SB + 1312)) $(($(get32 pb.img $((SB + 1312))) | 512))
fsck_ffs -f -y pb.img > /dev/null 2>&1
echo "  cgsize $(get32 pa.img $((SB + 160))) ncg $(get32 pa.img $((SB + 44)))"
sbinfo pa.img; sbinfo pb.img
for round in 1 2 3; do
	for i in pa pb; do
		on $i.img > /dev/null || continue
		/usr/bin/time -p sh -c "dd if=/dev/zero of=$M/big bs=64k count=6000 2>/dev/null; sync" 2>&1 |
		    tr '\n' ' ' | sed "s/^/  $round $i write-384MB: /"; echo
		/usr/bin/time -p sh -c "mkdir $M/m; cd $M/m; i=0; while [ \$i -lt 3000 ]; do : > f\$i; i=\$((i+1)); done; sync" 2>&1 |
		    tr '\n' ' ' | sed "s/^/  $round $i create-3000: /"; echo
		/usr/bin/time -p sh -c "rm -rf $M/m $M/big; sync" 2>&1 |
		    tr '\n' ' ' | sed "s/^/  $round $i remove: /"; echo
		off
	done
done
fsckn pb.img
