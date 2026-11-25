#!/bin/sh
# Runs inside the NetBSD guest as root: ck.sh <label> [T0 T1 ... T12]
# Check-hash tests on FreeBSD UFS2 images, plus quota2 and a benchmark.
# With no test named, runs T1 to T5.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
L=$1
P=/root/p/ck
V=vnd1
M=/mnt/p
cd $P || exit 1
cc -o poke poke.c || exit 1
cc -o fh fh.c || exit 1
mkdir -p $L && cd $L || exit 1
shift
T=" $* "; [ $# -eq 0 ] && T=" T1 T2 T3 T4 T5 "
want() { case $T in *" $1 "*) return 0;; esac; return 1; }
mkdir -p $M
echo "=== $L: $(uname -v)"
q() { grep -vE '^\*\* Phase|^$|DIOCGDINFO|character device|^CONTINUE'; }
mnt() {	# img opts...
	i=$1; shift
	vndconfig $V $i || return 1
	mount -t ffs "$@" /dev/${V}a $M; r=$?
	echo "mount $* $i -> rc=$r"; [ $r = 0 ] || dmesg | tail -2
	return $r
}
un() { umount $M 2>/dev/null; vndconfig -u $V; }
fk() { echo "--- fsck_ffs $*"; fsck_ffs "$@" 2>&1 | q; }

want T0 && {
echo "===== T0 CRC32C: known answers, and the time for one 32 KB cylinder group"
if [ -f src/ffs_ckhash.c ]; then
	cc -O2 -Iinclude -Isrc -o ../bench-$L ../bench.c && ../bench-$L
else
	echo "no source for $L"
fi

}
want T1 && {
echo "===== T1 FreeBSD eaonly: write, then check the hashes"
xz -dc ../eaonly.img.xz > e1.img
../poke e1.img flags
mnt e1.img && { cp -R /usr/share/misc $M/misc; rm $M/f3; mkdir $M/d; echo y > $M/d/y; ls $M | tr '\n' ' '; echo; }; un
../poke e1.img flags
fk -f -n e1.img
echo "--- dumpfs"; dumpfs -F e1.img 2>&1 | grep -E '^flags' | head -2

}
want T2 && {
echo "===== T2 corruption on FreeBSD plain"
for w in sb cg ino; do
	xz -dc ../plain.img.xz > c-$w.img
	../poke c-$w.img $w 4
	echo "--- $w: mount rw and touch"
	if mnt c-$w.img; then
		cat $M/hello; echo "cat rc=$?"
		dd if=/dev/zero of=$M/new bs=64k count=4 2>&1 | tail -1
		dmesg | tail -3
	fi
	un
	fk -f -n c-$w.img
	fk -f -y c-$w.img
	fk -f -n c-$w.img
	../poke c-$w.img flags
done

}
want T3 && {
echo "===== T3 WAPBL on FreeBSD eaonly"
xz -dc ../eaonly.img.xz > w.img
mnt w.img -o log && { cp -R /usr/share/misc $M/misc; mkdir $M/d; echo y > $M/d/y; sync; }; un
../poke w.img flags
fk -f -n w.img

}
want T4 && {
echo "===== T4 quota2"
dd if=/dev/zero of=q.img bs=1m count=32 2>/dev/null
newfs -F -s 32m -O2 -q user -q group q.img >/dev/null
mnt q.img && { echo q > $M/q; repquota -u $M | sed -n 1,4p; }; un
../poke q.img flags
fk -f -n q.img

}
want T5 && {
echo "===== T5 benchmark: 3000 files of 8 KB, extract + umount, 7 runs each, alternating"
[ -f ../bench.tar ] || { mkdir -p ../bt && i=0 && while [ $i -lt 3000 ]; do dd if=/dev/urandom of=../bt/f$i bs=8k count=1 2>/dev/null; i=$((i+1)); done && tar -C .. -cf ../bench.tar bt; }
dd if=/dev/zero of=nb.img bs=1m count=64 2>/dev/null
for run in 1 2 3 4 5 6 7; do
	for img in nb fbsd; do
		if [ $img = fbsd ]; then xz -dc ../plain.img.xz > b.img
		else cp nb.img b.img; newfs -F -s 64m -O2 b.img >/dev/null; fi
		mnt b.img >/dev/null || { echo "$img run $run: mount failed"; un; continue; }
		/usr/bin/time -p sh -c "tar -C $M -xf ../bench.tar && umount $M" 2> t.out
		echo "$img run $run: $(awk '/^real/{a=$2}/^user/{b=$2}/^sys/{c=$2}END{print "real "a" user "b" sys "c}' t.out)"
		vndconfig -u $V
	done
done
rm -f b.img nb.img
}
want T6 && {
echo "===== T6 cost of the hashes: the same FreeBSD UFS2 with and without them, 7 runs each, alternating"
[ -f ../bench.tar ] || { mkdir -p ../bt && i=0 && while [ $i -lt 3000 ]; do dd if=/dev/urandom of=../bt/f$i bs=8k count=1 2>/dev/null; i=$((i+1)); done && tar -C .. -cf ../bench.tar bt; }
xz -dc ../plain.img.xz > hash.img
cp hash.img nohash.img && ../poke nohash.img nohash
../poke hash.img flags; ../poke nohash.img flags
tm() {	# label command: time it, print real/user/sys
	/usr/bin/time -p sh -c "$2" 2> t.out
	printf ' %s %s' "$1" "$(awk '/^real/{a=$2}/^sys/{c=$2}END{print a"/"c}' t.out)"
}
for run in 1 2 3 4 5 6 7; do
	for img in hash nohash; do
		cp $img.img b.img
		mnt b.img >/dev/null || { echo "$img run $run: mount failed"; un; continue; }
		printf '%s run %s real/sys:' $img $run
		tm write "tar -C $M -xf ../bench.tar && umount $M"
		mount -t ffs /dev/${V}a $M
		tm stat "ls -lR $M > /dev/null && umount $M"
		mount -t ffs /dev/${V}a $M
		tm remove "rm -rf $M/bt && umount $M"
		echo
		vndconfig -u $V
		[ $run = 1 ] && fk -f -n b.img
	done
done
rm -f b.img hash.img nohash.img
}
want T8 && {
echo "===== T8 no log: a dirty cylinder group is read again for a file handle"
xz -dc ../plain.img.xz > h.img
mnt h.img && {
	for n in 1 2 3; do echo x > $M/a$n; ../fh $M/hello; echo "fh rc=$?"; done
}; un
fk -f -n h.img

}
want T9 && {
echo "===== T9 fsirand, then the inode check-hashes"
xz -dc ../plain.img.xz > r.img
fsirand -F r.img; echo "fsirand rc=$?"
fsck_ffs -f -n r.img > r.out 2>&1; echo "fsck_ffs rc=$?"
echo "BAD INODE CHECK HASH lines: $(grep -c 'BAD INODE CHECK HASH' r.out)"
q < r.out | grep -v 'BAD INODE CHECK HASH' | head -12
mnt r.img -o ro && { cat $M/hello; echo "cat rc=$?"; }; un

}
want T10 && {
echo "===== T10 resize_ffs grows it by 32 MB, then the check-hashes"
xz -dc ../plain.img.xz > g.img
dd if=/dev/zero bs=1m count=32 2>/dev/null >> g.img
ls -l g.img | awk '{print "size", $5}'
resize_ffs -y g.img; echo "resize_ffs rc=$?"
../poke g.img flags
fk -f -n g.img
mnt g.img && { cat $M/hello; echo "cat rc=$?"; echo y > $M/after; echo "write rc=$?"; df -k $M | tail -1; }; un
fk -f -n g.img

}
want T11 && {
echo "===== T11 the other byte order: fsck_ffs -B be, write, check, fsck_ffs -B le"
xz -dc ../plain.img.xz > s.img
fsck_ffs -B be -f -y s.img > s.out 2>&1; echo "fsck_ffs -B be rc=$?"; q < s.out | tail -5
fk -f -n s.img
mnt s.img && {
	cat $M/hello; echo "cat rc=$?"
	cp -R /usr/share/misc $M/misc; rm -f $M/misc/a*; mkdir $M/d; echo y > $M/d/y
	../fh $M/hello; echo "fh rc=$?"
}; un
fk -f -n s.img
fsck_ffs -B le -f -y s.img > s.out 2>&1; echo "fsck_ffs -B le rc=$?"; q < s.out | tail -5
fk -f -n s.img

}
want T12 && {
echo "===== T12 fsck_ffs -b: the first alternate superblock"
xz -dc ../plain.img.xz > a.img
b=$(dumpfs -F a.img 2>/dev/null | awk '{ for (i = 1; i < NF; i++) { if ($i == "sblkno") s = $(i+1); if ($i == "fsize") f = $(i+1) } } END { if (s > 0 && f > 0) print s * f / 512 }')
echo "alternate at sector ${b:-?}"
[ -n "$b" ] && fk -b $b -f -n a.img
rm -f a.img

}
echo "=== $L done"
