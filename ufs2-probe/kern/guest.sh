#!/bin/sh
# Runs inside NetBSD as root: guest.sh <label>
# Exercises writable mounts of FreeBSD UFS2 and of quota2 file systems.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
L=$1
P=/root/p
cd $P || exit 1
echo "=== $L: $(uname -v)"
[ -x q2 ] || cc -o q2 q2.c || exit 1
rm -rf $L && mkdir $L && cd $L
xz -dc ../plain.img.xz > plain.img
xz -dc ../eaonly.img.xz > eaonly.img
for n in q2ok q2bad; do
	dd if=/dev/zero of=$n.img bs=1m count=32 2>/dev/null
	newfs -F -s 32m -O2 -q user -q group $n.img >/dev/null
done
../q2 q2bad.img zero >/dev/null
mkdir -p /mnt/p
try() {	# tag img opts...
	t=$1; i=$2; shift 2
	vndconfig vnd1 $i || return 1
	mount -t ffs "$@" /dev/vnd1a /mnt/p; r=$?
	echo "[$t] mount $* $i -> rc=$r"
	[ $r = 0 ] || dmesg | tail -1
	return $r
}
un() { umount /mnt/p 2>/dev/null; vndconfig -u vnd1; }

try fresh-rw plain.img && { echo nb > /mnt/p/nb; ls /mnt/p | tr '\n' ' '; echo; }; un
try upgrade eaonly.img -o ro && {
	mount -u -o rw /mnt/p; echo "[upgrade] mount -u -o rw -> rc=$?"
	rm /mnt/p/f3 && echo nb > /mnt/p/nb &&
	    dd if=/dev/zero of=/mnt/p/fill bs=64k count=100 2>/dev/null &&
	    echo "[upgrade] wrote"
}; un
try quota2-ok q2ok.img && {
	echo q > /mnt/p/q; repquota -u /mnt/p | sed -n 1,4p
}; un
try quota2-badmagic q2bad.img; un
for f in plain eaonly q2ok q2bad; do ../q2 $f.img; done
fsck_ffs -n q2ok.img 2>&1 | tail -2
