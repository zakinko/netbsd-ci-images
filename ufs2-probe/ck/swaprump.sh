#!/bin/sh
# Runs inside the guest as root: swaprump.sh <dir>
# Install <dir>/librumpfs_ffs-*.so.xz over the snapshot's librumpfs_ffs.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
cd /root/p/ck || exit 1
L=$(ls /usr/lib/librumpfs_ffs.so.*.* | head -1)
[ -f $L.snap ] || cp $L $L.snap
xz -dc $1/librumpfs_ffs-*.so.xz > $L || exit 1
cksum -a sha256 $L
