#!/bin/sh
# Runs inside the NetBSD guest as root: ck.sh <label> [T1 T2 T3 T4 T5]
# Check-hash tests on FreeBSD UFS2 images, plus quota2 and a benchmark.
# With no test named, runs them all.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
L=$1
P=/root/p/ck
V=vnd1
M=/mnt/p
cd $P || exit 1
cc -o poke poke.c || exit 1
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

want T1 && {
echo "===== T1 FreeBSD eaonly: write, then check the hashes"
xz -dc ../eaonly.img.xz > e1.img
../poke e1.img flags
mnt e1.img && { cp -R /usr/share/misc $M/misc; rm $M/f3; mkdir $M/d; echo y > $M/d/y; ls $M | tr '\n' ' '; echo; }; un
../poke e1.img flags
fk -f -n e1.img

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
echo "===== T5 benchmark: 3000 files of 8 KB, extract + umount, 3 runs"
[ -f ../bench.tar ] || { mkdir -p ../bt && i=0 && while [ $i -lt 3000 ]; do dd if=/dev/urandom of=../bt/f$i bs=8k count=1 2>/dev/null; i=$((i+1)); done && tar -C .. -cf ../bench.tar bt; }
dd if=/dev/zero of=nb.img bs=1m count=64 2>/dev/null
for img in fbsd nb; do
	for r in 1 2 3; do
		if [ $img = fbsd ]; then xz -dc ../plain.img.xz > b.img
		else cp nb.img b.img; newfs -F -s 64m -O2 b.img >/dev/null; fi
		mnt b.img >/dev/null || { echo "$img run $r: mount failed"; un; continue; }
		t0=$(date +%s.%N 2>/dev/null || date +%s)
		/usr/bin/time -p sh -c "tar -C $M -xf ../bench.tar && umount $M" 2> t.out
		echo "$img run $r: $(awk '/^real/{r=$2}/^user/{u=$2}/^sys/{s=$2}END{print "real "r" user "u" sys "s}' t.out)"
		vndconfig -u $V
	done
done
}
echo "=== $L done"
