#!/bin/sh
# Runs inside the guest as root: install the patched kernel, fsck_ffs and
# rump ffs library, keeping the stock ones beside them.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
P=/root/p
cd $P || exit 1
cp /netbsd /netbsd.stock && xz -dc cur/netbsd.xz > /netbsd || exit 1
cp /sbin/fsck_ffs /sbin/fsck_ffs.stock && xz -dc cur/fsck_ffs.xz > /sbin/fsck_ffs && chmod 555 /sbin/fsck_ffs || exit 1
L=$(ls /usr/lib/librumpfs_ffs.so.*.* | head -1)
echo "rump lib: $L"
cp $L $L.stock && xz -dc cur/librumpfs_ffs.so.xz > $L || exit 1
cksum -a sha256 /netbsd /sbin/fsck_ffs $L
