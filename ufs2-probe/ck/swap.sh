#!/bin/sh
# Runs inside the guest as root: install the ffs-metackhash-v2 kernel,
# fsck_ffs, fsdb, tunefs and rump ffs library, keeping the stock ones.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
cd /root/p/ck || exit 1
cp /netbsd /netbsd.stock && xz -dc v2/netbsd.xz > /netbsd || exit 1
for p in sbin/fsck_ffs sbin/fsdb sbin/tunefs; do
	b=$(basename $p)
	cp /$p /$p.stock && xz -dc v2/$b.xz > /$p && chmod 555 /$p || exit 1
done
L=$(ls /usr/lib/librumpfs_ffs.so.*.* | head -1)
cp $L $L.stock && xz -dc v2/librumpfs_ffs.so.xz > $L || exit 1
cksum -a sha256 /netbsd /sbin/fsck_ffs /sbin/fsdb /sbin/tunefs $L
