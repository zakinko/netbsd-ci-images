#!/bin/sh
# FreeBSD side of the report's How-To-Repeat, for the image after the old
# and the new NetBSD fsck_ffs -f -y.
cd ufs2-probe/rep || exit 1
for v in old new; do
	echo "=================== $v"
	xz -dkf r-$v.img.xz
	md=$(mdconfig -a -t vnode -f r-$v.img)
	fsck_ffs -n /dev/$md 2>&1 | tail -2
	mount -o ro /dev/$md /mnt
	ls -l /mnt/f
	echo "getextattr: [$(getextattr -q user a /mnt/f 2>&1)]"
	umount /mnt
	mdconfig -d -u $md
done
