#!/bin/sh
# Runs inside the trunk chroot as root: fsck.sh <eaonly.img.xz>
# How fsck_ffs treats extattrs on a conversion to UFS2ea.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
W=/tmp/fsckx; rm -rf $W; mkdir -p $W/mnt; cd $W || exit 1
attr() {	# img: print user.t of every file with one
	vnconfig vnd2 $1 && mount -r -t ffs /dev/vnd2a mnt ||
	    { echo "  mount -r failed"; vnconfig -u vnd2; return; }
	for f in mnt/*; do
		v=$(getextattr -q user t $f 2>/dev/null) && echo "  $f user.t=$v"
		v=$(getextattr -q user probe $f 2>/dev/null) && echo "  $f user.probe=${v%%-*}-..."
	done
	umount mnt; vnconfig -u vnd2
}
magic() { dumpfs $1 2>/dev/null | sed -n 's/^magic[[:space:]]*\([0-9a-f]*\).*/magic \1/p' | head -1; }

echo "[ea-ea] UFS2ea with an extattr, then fsck -y -c ea"
newfs -O2ea -s 4m -F ea.img >/dev/null
vnconfig vnd2 ea.img && mount -t ffs /dev/vnd2a mnt &&
    touch mnt/a && setextattr user t kept mnt/a && umount mnt; vnconfig -u vnd2
fsck_ffs -y -c ea ea.img 2>&1 | grep -E 'EXTATTR|INCORRECT|MISSING|MODIFIED'
fsck_ffs -fn ea.img >/dev/null 2>&1; echo "  fsck -fn rc=$?"
attr ea.img

echo "[fb-plain] FreeBSD eaonly, fsck -f -y (no conversion)"
xz -dc $1 > fb.img
fsck_ffs -f -y fb.img 2>&1 | grep -E 'EXTATTR|PERMS|MODIFIED|files,'
magic fb.img
echo "[fb-ea] then fsck -y -c ea"
fsck_ffs -y -c ea fb.img > cvt.out 2>&1
echo "  CLEAR EXTATTR: $(grep -c 'CLEAR EXTATTR' cvt.out) inodes"
grep -E 'ENABLING|MODIFIED|files,' cvt.out
fsck_ffs -fn fb.img >/dev/null 2>&1; echo "  fsck -fn rc=$?"
magic fb.img
attr fb.img
