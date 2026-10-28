#!/bin/sh
# Runs inside the guest as root: swapu.sh <variant>
# Install u/newfs.<variant> and u/fsck_ffs.<variant> as /sbin/newfs and
# /sbin/fsck_ffs; both variants were built from the snapshot's own tree.
PATH=/sbin:/usr/sbin:/bin:/usr/bin; export PATH
cd /root/p/ck || exit 1
for b in newfs fsck_ffs; do
	[ -f /sbin/$b.snap ] || cp /sbin/$b /sbin/$b.snap
	xz -dc u/$b.$1.xz > /sbin/$b && chmod 555 /sbin/$b || exit 1
done
cksum -a sha256 /sbin/newfs /sbin/fsck_ffs
