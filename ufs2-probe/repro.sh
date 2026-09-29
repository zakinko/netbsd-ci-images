#!/bin/sh
# The How-To-Repeat steps of the fsck_ffs report, as written there.
set -x
mkdir -p out && cd out || exit 1
truncate -s 64m ufs2.img
md=$(mdconfig -a -t vnode -f ufs2.img)
newfs /dev/$md && mount /dev/$md /mnt
echo x > /mnt/f && setextattr user a b /mnt/f
ls -li /mnt/f; getextattr user a /mnt/f
umount /mnt && mdconfig -d -u $md
xz -k ufs2.img
