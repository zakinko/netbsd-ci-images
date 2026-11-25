#!/bin/sh
# ゲストの中で root として走る: install.sh <ctl|v5>
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
cd /root/p/ck/$1 || exit 1
cp netbsd /netbsd || exit 1
for p in fsck_ffs fsdb tunefs resize_ffs fsirand; do cp $p /sbin/$p && chmod 555 /sbin/$p || exit 1; done
cp dumpfs /usr/sbin/dumpfs && chmod 555 /usr/sbin/dumpfs || exit 1
L=$(ls /usr/lib/librumpfs_ffs.so.*.* | grep -v snap | head -1)
cp librumpfs_ffs.so $L || exit 1
cksum -a sha256 /netbsd /sbin/fsck_ffs /sbin/fsdb /sbin/tunefs /sbin/resize_ffs /sbin/fsirand /usr/sbin/dumpfs $L
